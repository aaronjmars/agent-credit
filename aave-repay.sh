#!/usr/bin/env bash
# aave-repay.sh — Repay Aave V3 debt on behalf of delegator
# Usage: aave-repay.sh <SYMBOL> <AMOUNT|max>
# Example: aave-repay.sh USDC 100
#          aave-repay.sh USDC max
set -euo pipefail

# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# === Parse arguments ===
if [ $# -lt 2 ]; then
  echo "Usage: aave-repay.sh <SYMBOL> <AMOUNT|max>"
  echo "Example: aave-repay.sh USDC 100"
  exit 1
fi

SYMBOL="$1"
AMOUNT="$2"

# === Load config ===
load_config
resolve_asset "$SYMBOL"

AGENT_ADDR=$(cast wallet address "$AGENT_PK")

if ! VAR_DEBT_TOKEN=$(resolve_var_debt_token "$ASSET_ADDR"); then
  exit 1
fi

DEBT_RAW=$(cast call "$VAR_DEBT_TOKEN" \
  "balanceOf(address)(uint256)" \
  "$DELEGATOR" \
  --rpc-url "$RPC_URL")
DEBT_RAW=$(echo "$DEBT_RAW" | strip_cast)
DEBT=$(from_units "$DEBT_RAW" "$DECIMALS")

echo "=== Aave V3 Debt Repayment ==="
echo "  Chain:      $CHAIN"
echo "  Asset:      $SYMBOL"
echo "  Delegator:  $DELEGATOR"
echo "  Agent:      $AGENT_ADDR"
echo "  Current debt: $DEBT $SYMBOL"
echo ""

if [ "$DEBT_RAW" = "0" ]; then
  echo -e "${YELLOW}⚠ No outstanding $SYMBOL debt for delegator${NC}"
  exit 0
fi

# One flag answers "is this a max repay?" everywhere below. It was previously
# asked three different ways — including by string-comparing the human amount
# against a bc-formatted debt figure.
if [ "$AMOUNT" = "max" ]; then
  IS_MAX_REPAY=true
  # type(uint256).max tells Aave to settle the exact debt at execution time
  # rather than a figure quoted a few seconds earlier.
  AMOUNT_RAW="$MAX_UINT"
  AMOUNT="$DEBT"
  echo "  Repaying: MAX (full debt = $DEBT $SYMBOL)"
else
  IS_MAX_REPAY=false
  AMOUNT_RAW=$(to_units "$AMOUNT" "$DECIMALS")
  echo "  Repaying: $AMOUNT $SYMBOL ($AMOUNT_RAW raw)"
fi

# Check agent has enough tokens to repay
AGENT_BALANCE_RAW=$(cast call "$ASSET_ADDR" \
  "balanceOf(address)(uint256)" \
  "$AGENT_ADDR" \
  --rpc-url "$RPC_URL")
AGENT_BALANCE_RAW=$(echo "$AGENT_BALANCE_RAW" | strip_cast)
AGENT_BALANCE=$(from_units "$AGENT_BALANCE_RAW" "$DECIMALS")

echo "  Agent $SYMBOL balance: $AGENT_BALANCE"

if [ "$IS_MAX_REPAY" = true ]; then
  NEEDED_RAW="$DEBT_RAW"
else
  NEEDED_RAW="$AMOUNT_RAW"
fi

if (( $(echo "$AGENT_BALANCE_RAW < $NEEDED_RAW" | bc) )); then
  echo -e "${RED}✗ Agent doesn't have enough $SYMBOL to repay${NC}"
  echo "  Has: $AGENT_BALANCE $SYMBOL"
  echo "  Needs: $AMOUNT $SYMBOL"
  exit 1
fi
echo -e "${GREEN}✓${NC} Agent has sufficient $SYMBOL"

# The debt keeps accruing between this read and execution, and Aave pulls the
# amount owed at execution time. A balance that only just covers the figure
# read above can therefore still revert in transferFrom. Warn rather than
# block: the shortfall is usually far smaller than the 1% approval buffer.
if [ "$IS_MAX_REPAY" = true ]; then
  BUFFERED_RAW=$(echo "$DEBT_RAW * 101 / 100" | bc)
  if (( $(echo "$AGENT_BALANCE_RAW < $BUFFERED_RAW" | bc) )); then
    echo -e "${YELLOW}⚠${NC} Balance covers the debt read just now but leaves under 1% headroom."
    echo "  If interest accrues before this lands, the repay may revert. Consider"
    echo "  repaying a fixed amount slightly below your balance instead of 'max'."
  fi
fi

echo ""
echo "--- Step 1: Approve Pool ---"

EXISTING_ALLOWANCE=$(cast call "$ASSET_ADDR" \
  "allowance(address,address)(uint256)" \
  "$AGENT_ADDR" "$POOL" \
  --rpc-url "$RPC_URL")
EXISTING_ALLOWANCE=$(echo "$EXISTING_ALLOWANCE" | strip_cast)

if [ "$IS_MAX_REPAY" = true ]; then
  # 1% buffer for interest accruing between approval and repay.
  APPROVE_AMOUNT="$BUFFERED_RAW"
else
  APPROVE_AMOUNT="$AMOUNT_RAW"
fi

if (( $(echo "$EXISTING_ALLOWANCE >= $APPROVE_AMOUNT" | bc) )); then
  echo -e "${GREEN}✓${NC} Pool already has sufficient allowance"
else
  echo "  Approving Pool to spend $SYMBOL..."
  # Capture the exit code rather than the parsed hash. The previous shape
  # discarded stderr and re-sent the approve whenever the hash came back
  # empty — including when the first send had actually succeeded and only the
  # JSON parse failed, which spends gas on a redundant approval.
  APPROVE_EXIT=0
  APPROVE_OUT=$(cast send "$ASSET_ADDR" \
    "approve(address,uint256)" \
    "$POOL" \
    "$APPROVE_AMOUNT" \
    --private-key "$AGENT_PK" \
    --rpc-url "$RPC_URL" \
    --json 2>&1) || APPROVE_EXIT=$?

  if [ $APPROVE_EXIT -ne 0 ]; then
    echo -e "${RED}✗ APPROVE_FAILED: $APPROVE_OUT${NC}"
    exit 1
  fi

  APPROVE_TX=$(printf '%s' "$APPROVE_OUT" | jq -r '.transactionHash // .hash // empty' 2>/dev/null || echo "")
  if [ -n "$APPROVE_TX" ]; then
    echo -e "${GREEN}✓${NC} Approved. TX: $APPROVE_TX"
  else
    echo -e "${GREEN}✓${NC} Approved (receipt not parseable, but the send succeeded)"
  fi
fi

echo ""
echo "--- Step 2: Repay ---"

# On a max repay AMOUNT_RAW is type(uint256).max, which tells Aave to settle
# the exact debt at execution time rather than a stale quoted amount.
REPAY_AMOUNT="$AMOUNT_RAW"

echo "  Pool.repay($ASSET_ADDR, $REPAY_AMOUNT, 2, $DELEGATOR)"

# Capture the exit code without aborting, so the error path below can run
# (under `set -e`, a top-level `var=$(cmd)` exits the script when cmd fails).
#
# A repay is NOT idempotent: it pulls the agent's tokens each time. The
# previous shape re-sent this transaction whenever no hash could be parsed,
# which includes the case where the first send landed on-chain and only the
# response failed to parse. There is no retry here for that reason.
TX_EXIT=0
TX_OUTPUT=$(cast send "$POOL" \
  "repay(address,uint256,uint256,address)" \
  "$ASSET_ADDR" \
  "$REPAY_AMOUNT" \
  2 \
  "$DELEGATOR" \
  --private-key "$AGENT_PK" \
  --rpc-url "$RPC_URL" \
  --json 2>&1) || TX_EXIT=$?

if [ $TX_EXIT -ne 0 ]; then
  echo -e "${RED}✗ REPAY_FAILED: $TX_OUTPUT${NC}"
  echo "  The transaction may or may not have been broadcast. Check the"
  echo "  delegator's debt with ./aave-status.sh $SYMBOL before retrying."
  exit 1
fi

if ! TX_HASH=$(printf '%s' "$TX_OUTPUT" | jq -r '.transactionHash // .hash // empty' 2>/dev/null); then
  echo -e "${RED}✗ REPAY_SENT_BUT_UNPARSEABLE: the repay was submitted successfully"
  echo -e "  but its receipt could not be parsed. DO NOT RETRY.${NC}"
  echo "  Raw output: $TX_OUTPUT"
  echo "  Verify with: ./aave-status.sh $SYMBOL"
  exit 1
fi

# Only an explicit failure status counts as a revert; cast versions that omit
# the field leave this empty and fall through. Previously a reverted receipt
# was reported as success, because the hash was scraped with a bare grep that
# matched blockHash (which Foundry prints first) and a reverted receipt still
# contains one.
TX_STATUS=$(printf '%s' "$TX_OUTPUT" | jq -r '.status // empty' 2>/dev/null || echo "")
if [ "$TX_STATUS" = "0x0" ] || [ "$TX_STATUS" = "0" ]; then
  echo -e "${RED}✗ REPAY_REVERTED: transaction $TX_HASH was mined but reverted${NC}"
  echo "  The debt was NOT repaid. Gas was still spent."
  echo "  A max repay can revert if accrued interest exceeded the 1% approval"
  echo "  buffer; re-running will re-quote the debt."
  exit 1
fi

if [ -n "$TX_HASH" ]; then
  echo -e "${GREEN}✓ Repayment successful!${NC}"
  echo "  TX: $TX_HASH"
  
  # Check remaining debt
  sleep 2  # wait for state update
  NEW_DEBT_RAW=$(cast call "$VAR_DEBT_TOKEN" \
    "balanceOf(address)(uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
  NEW_DEBT_RAW=$(echo "$NEW_DEBT_RAW" | strip_cast)
  if [ "$NEW_DEBT_RAW" != "?" ]; then
    NEW_DEBT=$(from_units "$NEW_DEBT_RAW" "$DECIMALS")
    echo "  Remaining $SYMBOL debt: $NEW_DEBT"
  fi
  
  NEW_ACCOUNT=$(cast call "$POOL" \
    "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  if [ -n "$NEW_ACCOUNT" ]; then
    NEW_HF_RAW=$(echo "$NEW_ACCOUNT" | sed -n '6p' | strip_cast)
    if [ "$NEW_HF_RAW" = "$MAX_UINT" ]; then
      echo "  Health factor: ∞ (all debt repaid)"
    else
      NEW_HF=$(hf_from_raw "$NEW_HF_RAW")
      echo "  Health factor: $NEW_HF"
    fi
  fi
else
  echo -e "${RED}✗ Repayment may have failed. Check status manually.${NC}"
  exit 1
fi
