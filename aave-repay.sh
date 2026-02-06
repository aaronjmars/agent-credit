#!/usr/bin/env bash
# aave-repay.sh — Repay Aave V3 debt on behalf of delegator
# Usage: aave-repay.sh <SYMBOL> <AMOUNT|max>
# Example: aave-repay.sh USDC 100
#          aave-repay.sh USDC max
set -euo pipefail

# Strip cast's bracket annotations e.g. "7920000000000000 [7.92e15]" → "7920000000000000"
strip_cast() { sed 's/ *\[.*\]//' | tr -d ' '; }

SKILL_DIR="${SKILL_DIR:-$HOME/.openclaw/skills/aave-delegation}"
CONFIG="$SKILL_DIR/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === Parse arguments ===
if [ $# -lt 2 ]; then
  echo "Usage: aave-repay.sh <SYMBOL> <AMOUNT|max>"
  echo "Example: aave-repay.sh USDC 100"
  exit 1
fi

SYMBOL="$1"
AMOUNT="$2"

# === Load config ===
RPC_URL="${AAVE_RPC_URL:-$(jq -r '.rpcUrl' "$CONFIG")}"
AGENT_PK="${AAVE_AGENT_PRIVATE_KEY:-$(jq -r '.agentPrivateKey' "$CONFIG")}"
DELEGATOR="${AAVE_DELEGATOR_ADDRESS:-$(jq -r '.delegatorAddress' "$CONFIG")}"
POOL="${AAVE_POOL_ADDRESS:-$(jq -r '.poolAddress' "$CONFIG")}"
DATA_PROVIDER=$(jq -r '.dataProviderAddress' "$CONFIG")
CHAIN=$(jq -r '.chain // "unknown"' "$CONFIG")

ASSET_ADDR=$(jq -r ".assets[\"$SYMBOL\"].address // empty" "$CONFIG")
DECIMALS=$(jq -r ".assets[\"$SYMBOL\"].decimals // empty" "$CONFIG")

if [ -z "$ASSET_ADDR" ] || [ -z "$DECIMALS" ]; then
  echo -e "${RED}✗ Asset $SYMBOL not found in config${NC}"
  exit 1
fi

AGENT_ADDR=$(cast wallet address "$AGENT_PK")
MAX_UINT="115792089237316195423570985008687907853269984665640564039457584007913129639935"

# Resolve variable debt token
TOKENS=$(cast call "$DATA_PROVIDER" \
  "getReserveTokensAddresses(address)(address,address,address)" \
  "$ASSET_ADDR" \
  --rpc-url "$RPC_URL")
VAR_DEBT_TOKEN=$(echo "$TOKENS" | sed -n '3p' | strip_cast)

# Check current debt
DEBT_RAW=$(cast call "$VAR_DEBT_TOKEN" \
  "balanceOf(address)(uint256)" \
  "$DELEGATOR" \
  --rpc-url "$RPC_URL")
DEBT_RAW=$(echo "$DEBT_RAW" | strip_cast)
DEBT=$(echo "scale=$DECIMALS; $DEBT_RAW / (10^$DECIMALS)" | bc)

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

# Handle "max" repayment
if [ "$AMOUNT" = "max" ]; then
  # For max repay, use type(uint256).max which tells Aave to repay the full debt
  AMOUNT_RAW="$MAX_UINT"
  AMOUNT="$DEBT"
  echo "  Repaying: MAX (full debt = $DEBT $SYMBOL)"
else
  AMOUNT_RAW=$(echo "$AMOUNT * (10^$DECIMALS)" | bc | cut -d'.' -f1)
  echo "  Repaying: $AMOUNT $SYMBOL ($AMOUNT_RAW raw)"
fi

# Check agent has enough tokens to repay
AGENT_BALANCE_RAW=$(cast call "$ASSET_ADDR" \
  "balanceOf(address)(uint256)" \
  "$AGENT_ADDR" \
  --rpc-url "$RPC_URL")
AGENT_BALANCE_RAW=$(echo "$AGENT_BALANCE_RAW" | strip_cast)
AGENT_BALANCE=$(echo "scale=$DECIMALS; $AGENT_BALANCE_RAW / (10^$DECIMALS)" | bc)

echo "  Agent $SYMBOL balance: $AGENT_BALANCE"

# For max repay, we need at least the debt amount
NEEDED_RAW="$DEBT_RAW"
if [ "$AMOUNT" != "$DEBT" ]; then
  NEEDED_RAW="$AMOUNT_RAW"
fi

if (( $(echo "$AGENT_BALANCE_RAW < $NEEDED_RAW" | bc) )); then
  echo -e "${RED}✗ Agent doesn't have enough $SYMBOL to repay${NC}"
  echo "  Has: $AGENT_BALANCE $SYMBOL"
  echo "  Needs: $AMOUNT $SYMBOL"
  exit 1
fi
echo -e "${GREEN}✓${NC} Agent has sufficient $SYMBOL"

# === Step 1: Approve Pool to spend tokens ===
echo ""
echo "--- Step 1: Approve Pool ---"

# Check existing allowance
EXISTING_ALLOWANCE=$(cast call "$ASSET_ADDR" \
  "allowance(address,address)(uint256)" \
  "$AGENT_ADDR" "$POOL" \
  --rpc-url "$RPC_URL")
EXISTING_ALLOWANCE=$(echo "$EXISTING_ALLOWANCE" | strip_cast)

# Determine approval amount
if [ "$AMOUNT_RAW" = "$MAX_UINT" ]; then
  APPROVE_AMOUNT="$DEBT_RAW"
  # Add 1% buffer for accrued interest between approval and repay
  APPROVE_AMOUNT=$(echo "$APPROVE_AMOUNT * 101 / 100" | bc)
else
  APPROVE_AMOUNT="$AMOUNT_RAW"
fi

if (( $(echo "$EXISTING_ALLOWANCE >= $APPROVE_AMOUNT" | bc) )); then
  echo -e "${GREEN}✓${NC} Pool already has sufficient allowance"
else
  echo "  Approving Pool to spend $SYMBOL..."
  APPROVE_TX=$(cast send "$ASSET_ADDR" \
    "approve(address,uint256)" \
    "$POOL" \
    "$APPROVE_AMOUNT" \
    --private-key "$AGENT_PK" \
    --rpc-url "$RPC_URL" \
    --json 2>/dev/null | jq -r '.transactionHash // .hash // empty' || echo "")
  
  if [ -z "$APPROVE_TX" ]; then
    # Fallback without --json
    cast send "$ASSET_ADDR" \
      "approve(address,uint256)" \
      "$POOL" \
      "$APPROVE_AMOUNT" \
      --private-key "$AGENT_PK" \
      --rpc-url "$RPC_URL"
  else
    echo -e "${GREEN}✓${NC} Approved. TX: $APPROVE_TX"
  fi
fi

# === Step 2: Execute Repay ===
echo ""
echo "--- Step 2: Repay ---"

# For max repay, pass type(uint256).max so Aave repays exact debt amount
if [ "$AMOUNT_RAW" = "$MAX_UINT" ]; then
  REPAY_AMOUNT="$MAX_UINT"
else
  REPAY_AMOUNT="$AMOUNT_RAW"
fi

echo "  Pool.repay($ASSET_ADDR, $REPAY_AMOUNT, 2, $DELEGATOR)"

TX_HASH=$(cast send "$POOL" \
  "repay(address,uint256,uint256,address)" \
  "$ASSET_ADDR" \
  "$REPAY_AMOUNT" \
  2 \
  "$DELEGATOR" \
  --private-key "$AGENT_PK" \
  --rpc-url "$RPC_URL" \
  --json 2>/dev/null | jq -r '.transactionHash // .hash // empty')

if [ -z "$TX_HASH" ]; then
  TX_OUTPUT=$(cast send "$POOL" \
    "repay(address,uint256,uint256,address)" \
    "$ASSET_ADDR" \
    "$REPAY_AMOUNT" \
    2 \
    "$DELEGATOR" \
    --private-key "$AGENT_PK" \
    --rpc-url "$RPC_URL" 2>&1)
  echo "$TX_OUTPUT"
  TX_HASH=$(echo "$TX_OUTPUT" | grep -oE '0x[a-fA-F0-9]{64}' | head -1 || echo "")
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
    NEW_DEBT=$(echo "scale=$DECIMALS; $NEW_DEBT_RAW / (10^$DECIMALS)" | bc)
    echo "  Remaining $SYMBOL debt: $NEW_DEBT"
  fi
  
  # Check new health factor
  NEW_ACCOUNT=$(cast call "$POOL" \
    "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  if [ -n "$NEW_ACCOUNT" ]; then
    NEW_HF_RAW=$(echo "$NEW_ACCOUNT" | sed -n '6p' | strip_cast)
    if [ "$NEW_HF_RAW" = "$MAX_UINT" ]; then
      echo "  Health factor: ∞ (all debt repaid)"
    else
      NEW_HF=$(echo "scale=4; $NEW_HF_RAW / 1000000000000000000" | bc)
      echo "  Health factor: $NEW_HF"
    fi
  fi
else
  echo -e "${RED}✗ Repayment may have failed. Check status manually.${NC}"
  exit 1
fi
