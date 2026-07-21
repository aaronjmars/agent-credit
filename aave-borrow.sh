#!/usr/bin/env bash
# aave-borrow.sh — Borrow from Aave V3 via credit delegation
# Usage: aave-borrow.sh <SYMBOL> <AMOUNT>
# Example: aave-borrow.sh USDC 100
set -euo pipefail

# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# === Parse arguments ===
if [ $# -lt 2 ]; then
  echo "Usage: aave-borrow.sh <SYMBOL> <AMOUNT>"
  echo "Example: aave-borrow.sh USDC 100"
  exit 1
fi

SYMBOL="$1"
AMOUNT="$2"

# === Load config ===
load_config
resolve_asset "$SYMBOL"

AGENT_ADDR=$(cast wallet address "$AGENT_PK")

# Validate the borrow amount before it reaches bc. A negative amount otherwise
# passes every safety check — the cap comparison passes, and a negative debt
# delta *raises* the projected health factor — before failing at the ABI layer.
# A sub-unit amount truncates to an empty string and crashes bc with no
# diagnostic.
if ! [[ "$AMOUNT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [ "$(echo "$AMOUNT > 0" | bc)" != "1" ]; then
  echo -e "${RED}✗ INVALID_AMOUNT: '$AMOUNT' must be a positive decimal number${NC}"
  exit 1
fi

# Convert human amount to raw (e.g., 100 USDC → 100000000)
AMOUNT_RAW=$(to_units "$AMOUNT" "$DECIMALS")

if [ -z "$AMOUNT_RAW" ] || [ "$AMOUNT_RAW" = "0" ]; then
  echo -e "${RED}✗ INVALID_AMOUNT: '$AMOUNT' rounds to zero at $DECIMALS decimals${NC}"
  exit 1
fi

# Safety config
MIN_HF="${AAVE_MIN_HEALTH_FACTOR:-$(jq -r '.safety.minHealthFactor // "1.5"' "$CONFIG")}"
MAX_BORROW=$(jq -r '.safety.maxBorrowPerTx // "1000"' "$CONFIG")
MAX_BORROW_UNIT=$(jq -r '.safety.maxBorrowPerTxUnit // "USDC"' "$CONFIG")

# Both thresholds are only ever consumed inside `if (( $(... | bc) ))`, where a
# bc parse error expands to `(( ))` — which bash evaluates as false — and where
# `set -e` does not apply. A non-numeric or empty value therefore disables the
# check silently rather than failing. Validate here, at the boundary.
if ! [[ "$MIN_HF" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo -e "${RED}✗ INVALID_CONFIG: safety.minHealthFactor '$MIN_HF' is not a positive decimal${NC}"
  exit 1
fi
if ! [[ "$MAX_BORROW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo -e "${RED}✗ INVALID_CONFIG: safety.maxBorrowPerTx '$MAX_BORROW' is not a positive decimal${NC}"
  exit 1
fi

# Gas units for the borrow tx. Safety Check 4 reserves this much gas and the
# send below caps at it, so the two must stay equal — if the cap were higher
# than the reservation, Check 4 could pass on a balance the tx can outspend.
BORROW_GAS_LIMIT=500000

# Safety Check 1 (cross-asset cap) and Safety Check 3 (projected health
# factor) both convert the borrow amount into the pool's base currency, so
# resolve the oracle once here.
init_base_currency

ADDRESSES_PROVIDER=$(cast call "$POOL" "ADDRESSES_PROVIDER()(address)" \
  --rpc-url "$RPC_URL" | strip_cast)
ORACLE=$(cast call "$ADDRESSES_PROVIDER" "getPriceOracle()(address)" \
  --rpc-url "$RPC_URL" | strip_cast)
ASSET_PRICE=$(cast call "$ORACLE" "getAssetPrice(address)(uint256)" \
  "$ASSET_ADDR" --rpc-url "$RPC_URL" | strip_cast)

# getAssetPrice returns 0 rather than reverting when the oracle has no price
# source for an address — which is what a typo'd or wrong-chain asset address
# in config looks like. A zero price makes BORROW_BASE 0, and both value-based
# safety checks then pass for ANY amount: the cap compares 0 against the cap,
# and the HF projection adds 0 to existing debt. Refuse to price-blind borrow.
if [ -z "$ASSET_PRICE" ] || [ "$ASSET_PRICE" = "0" ]; then
  echo -e "${RED}✗ ORACLE_PRICE_UNAVAILABLE: oracle returned 0 for $SYMBOL ($ASSET_ADDR)${NC}"
  echo "  Cannot value this borrow, so the per-tx cap and the health-factor"
  echo "  projection would both pass vacuously."
  echo "  Check that the $SYMBOL address in $CONFIG is correct for this chain."
  exit 1
fi

BORROW_BASE=$(echo "$AMOUNT_RAW * $ASSET_PRICE / (10^$DECIMALS)" | bc)
BORROW_USD=$(to_usd "$BORROW_BASE")

echo "=== Aave V3 Credit Delegation Borrow ==="
echo "  Chain:      $CHAIN"
echo "  Asset:      $SYMBOL ($ASSET_ADDR)"
echo "  Amount:     $AMOUNT $SYMBOL ($AMOUNT_RAW raw, ~\$$BORROW_USD)"
echo "  Delegator:  $DELEGATOR"
echo "  Agent:      $AGENT_ADDR"
echo "  Pool:       $POOL"
echo ""

# === SAFETY CHECK 1: Per-transaction cap ===
echo "--- Safety Check 1: Transaction Cap ---"
# Compare in base currency so the cap binds across assets — borrowing 1 WETH
# against a "1000 USDC" cap must be rejected, not silently passed.
CAP_ASSET_ADDR=$(jq -r ".assets[\"$MAX_BORROW_UNIT\"].address // empty" "$CONFIG")
if [ -z "$CAP_ASSET_ADDR" ]; then
  echo -e "${RED}✗ CAP_UNIT_NOT_CONFIGURED: safety.maxBorrowPerTxUnit '$MAX_BORROW_UNIT' is not in config.assets${NC}"
  echo "  Add '$MAX_BORROW_UNIT' to assets, or set maxBorrowPerTxUnit to a configured asset."
  exit 1
fi
CAP_PRICE=$(cast call "$ORACLE" "getAssetPrice(address)(uint256)" \
  "$CAP_ASSET_ADDR" --rpc-url "$RPC_URL" | strip_cast)
# A zero cap price collapses CAP_BASE to 0, which would reject every borrow
# rather than permit one — but the diagnostic would be an unrelated
# AMOUNT_EXCEEDS_CAP, so fail with the real reason.
if [ -z "$CAP_PRICE" ] || [ "$CAP_PRICE" = "0" ]; then
  echo -e "${RED}✗ ORACLE_PRICE_UNAVAILABLE: oracle returned 0 for the cap unit $MAX_BORROW_UNIT ($CAP_ASSET_ADDR)${NC}"
  echo "  Check that the $MAX_BORROW_UNIT address in $CONFIG is correct for this chain."
  exit 1
fi
CAP_BASE=$(echo "$MAX_BORROW * $CAP_PRICE" | bc | cut -d'.' -f1)
CAP_USD=$(to_usd "$CAP_BASE")

if (( $(echo "$BORROW_BASE > $CAP_BASE" | bc) )); then
  echo -e "${RED}✗ AMOUNT_EXCEEDS_CAP: $AMOUNT $SYMBOL (~\$$BORROW_USD) exceeds cap $MAX_BORROW $MAX_BORROW_UNIT (~\$$CAP_USD)${NC}"
  echo "  Update safety.maxBorrowPerTx in config to increase limit."
  exit 1
fi
echo -e "${GREEN}✓${NC} Amount within per-tx cap (~\$$BORROW_USD ≤ ~\$$CAP_USD)"

# === SAFETY CHECK 2: Delegation allowance ===
echo "--- Safety Check 2: Delegation Allowance ---"

if ! VAR_DEBT_TOKEN=$(resolve_var_debt_token "$ASSET_ADDR"); then
  exit 1
fi

ALLOWANCE_RAW=$(cast call "$VAR_DEBT_TOKEN" \
  "borrowAllowance(address,address)(uint256)" \
  "$DELEGATOR" "$AGENT_ADDR" \
  --rpc-url "$RPC_URL")
ALLOWANCE_RAW=$(echo "$ALLOWANCE_RAW" | strip_cast)
ALLOWANCE=$(from_units "$ALLOWANCE_RAW" "$DECIMALS")

if [ "$ALLOWANCE_RAW" = "0" ]; then
  echo -e "${RED}✗ INSUFFICIENT_ALLOWANCE: No delegation for $SYMBOL${NC}"
  echo "  Delegator must call: approveDelegation($AGENT_ADDR, amount) on $VAR_DEBT_TOKEN"
  exit 1
fi

if (( $(echo "$AMOUNT_RAW > $ALLOWANCE_RAW" | bc) )); then
  echo -e "${RED}✗ INSUFFICIENT_ALLOWANCE: Need $AMOUNT $SYMBOL but only $ALLOWANCE $SYMBOL delegated${NC}"
  echo "  Delegator must increase delegation on $VAR_DEBT_TOKEN"
  exit 1
fi
echo -e "${GREEN}✓${NC} Delegation allowance sufficient: $ALLOWANCE $SYMBOL available"

# === SAFETY CHECK 3: Health factor ===
echo "--- Safety Check 3: Health Factor ---"

ACCOUNT_DATA=$(cast call "$POOL" \
  "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
  "$DELEGATOR" \
  --rpc-url "$RPC_URL")

TOTAL_COLLATERAL=$(echo "$ACCOUNT_DATA" | sed -n '1p' | strip_cast)
TOTAL_DEBT=$(echo "$ACCOUNT_DATA" | sed -n '2p' | strip_cast)
AVAILABLE_BORROWS=$(echo "$ACCOUNT_DATA" | sed -n '3p' | strip_cast)
LIQ_THRESHOLD=$(echo "$ACCOUNT_DATA" | sed -n '4p' | strip_cast)
HEALTH_FACTOR_RAW=$(echo "$ACCOUNT_DATA" | sed -n '6p' | strip_cast)

if [ "$HEALTH_FACTOR_RAW" = "$MAX_UINT" ]; then
  HF="999"  # effectively infinite
  HF_DISPLAY="∞ (no current debt)"
else
  HF=$(hf_from_raw "$HEALTH_FACTOR_RAW")
  HF_DISPLAY="$HF"
fi

COLLATERAL_USD=$(to_usd "$TOTAL_COLLATERAL")
DEBT_USD=$(to_usd "$TOTAL_DEBT")

echo "  Current HF:     $HF_DISPLAY"
echo "  Collateral:     \$$COLLATERAL_USD"
echo "  Existing debt:  \$$DEBT_USD"

# The 999 test is not redundant: it keeps a no-debt account (whose HF is
# infinite) from being rejected by an absurdly high configured minimum.
if (( $(echo "$HF < $MIN_HF" | bc -l) )) && [ "$HF" != "999" ]; then
  echo -e "${RED}✗ HEALTH_FACTOR_TOO_LOW: Current HF ($HF) is already below minimum ($MIN_HF)${NC}"
  echo "  Delegator should add collateral or repay debt before agent borrows more."
  exit 1
fi

if [ "$AVAILABLE_BORROWS" = "0" ]; then
  echo -e "${RED}✗ No available borrowing capacity for delegator${NC}"
  exit 1
fi

# Project HF after this borrow — Aave only reverts at HF<1.0, so without
# this check the script would silently honour borrows that drop HF below
# the configured MIN_HF (e.g. 1.5 → 1.05). LIQ_THRESHOLD is in bps.
ADJ_COLLATERAL=$(echo "$TOTAL_COLLATERAL * $LIQ_THRESHOLD / 10000" | bc)
PROJ_DEBT=$(echo "$TOTAL_DEBT + $BORROW_BASE" | bc)
if [ "$PROJ_DEBT" = "0" ]; then
  PROJ_HF_DISPLAY="∞"
  PROJ_HF="999"
else
  PROJ_HF=$(echo "scale=4; $ADJ_COLLATERAL / $PROJ_DEBT" | bc)
  PROJ_HF_DISPLAY="$PROJ_HF"
fi

if (( $(echo "$PROJ_HF < $MIN_HF" | bc -l) )); then
  echo -e "${RED}✗ PROJECTED_HF_BELOW_MIN: borrow would drop HF to $PROJ_HF_DISPLAY (minimum: $MIN_HF)${NC}"
  echo "  Reduce borrow amount, add collateral, or repay existing debt."
  exit 1
fi

echo -e "${GREEN}✓${NC} Health factor OK: $HF_DISPLAY → $PROJ_HF_DISPLAY post-borrow (minimum: $MIN_HF)"

# === SAFETY CHECK 4: Agent has enough gas ===
echo "--- Safety Check 4: Gas Balance ---"
AGENT_BALANCE=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC_URL")
AGENT_ETH=$(cast from-wei "$AGENT_BALANCE")
# Aave borrow tx uses ~300k-500k gas. Estimate cost conservatively.
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo "")

# If the gas-price query failed or returned 0 (transient RPC issue, or a
# chain that doesn't expose eth_gasPrice the way cast expects), fall back to
# a conservative floor instead of multiplying through with 0. Otherwise
# MIN_GAS_WEI collapses to 0 and the `$AGENT_BALANCE < 0` comparison below
# silently green-lights any non-zero balance. 1e14 wei = 0.0001 ETH covers a
# 500k-gas borrow at ~200 gwei on every EVM chain Aave is deployed on.
if [ -z "$GAS_PRICE" ] || [ "$GAS_PRICE" = "0" ]; then
  MIN_GAS_WEI="100000000000000"
  GAS_NOTE=" (RPC gas-price unavailable — using 0.0001 ETH floor)"
else
  MIN_GAS_WEI=$(echo "$GAS_PRICE * $BORROW_GAS_LIMIT" | bc)
  GAS_NOTE=""
fi

MIN_GAS_ETH=$(cast from-wei "$MIN_GAS_WEI")
if [ "$AGENT_BALANCE" = "0" ]; then
  echo -e "${RED}✗ INSUFFICIENT_GAS: Agent wallet has 0 ETH${NC}"
  echo "  Send at least $MIN_GAS_ETH ETH to $AGENT_ADDR on $CHAIN for gas."
  exit 1
elif (( $(echo "$AGENT_BALANCE < $MIN_GAS_WEI" | bc) )); then
  echo -e "${RED}✗ INSUFFICIENT_GAS: Agent has $AGENT_ETH ETH but needs ~$MIN_GAS_ETH ETH for gas${NC}"
  echo "  Send at least $MIN_GAS_ETH ETH to $AGENT_ADDR on $CHAIN."
  exit 1
fi
echo -e "${GREEN}✓${NC} Agent gas balance: $AGENT_ETH ETH$GAS_NOTE"

# === EXECUTE BORROW ===
echo ""
echo "=== Executing Borrow ==="
echo "  Pool.borrow($ASSET_ADDR, $AMOUNT_RAW, 2, 0, $DELEGATOR)"
echo ""

# interestRateMode: 2 = variable rate
# referralCode: 0 (inactive)
# onBehalfOf: delegator address (debt goes to them)
# Capture without aborting on non-zero so the error parser below can run
# (under `set -e`, a top-level `var=$(cmd)` exits the script when cmd fails).
TX_EXIT=0
TX_OUTPUT=$(cast send "$POOL" \
  "borrow(address,uint256,uint256,uint16,address)" \
  "$ASSET_ADDR" \
  "$AMOUNT_RAW" \
  2 \
  0 \
  "$DELEGATOR" \
  --private-key "$AGENT_PK" \
  --rpc-url "$RPC_URL" \
  --gas-limit "$BORROW_GAS_LIMIT" \
  --json 2>&1) || TX_EXIT=$?

if [ $TX_EXIT -ne 0 ]; then
  # Parse common errors into human-readable messages
  if echo "$TX_OUTPUT" | grep -qi "insufficient funds"; then
    echo -e "${RED}✗ INSUFFICIENT_GAS: Agent wallet can't afford gas for this transaction.${NC}"
    echo "  Send more ETH to $AGENT_ADDR on $CHAIN."
  elif echo "$TX_OUTPUT" | grep -qi "revert"; then
    # Decode Aave-specific revert reasons. Named reasons are matched first: the
    # panic check below is a substring test, and cast's output routinely
    # contains addresses and calldata that happen to include "0x11", so
    # matching it first would shadow every accurate reason with a guess.
    REASON=""
    if echo "$TX_OUTPUT" | grep -qi "BORROWING_NOT_ENABLED"; then
      REASON="Borrowing is not enabled for $SYMBOL on this pool"
    elif echo "$TX_OUTPUT" | grep -qi "COLLATERAL_CANNOT_COVER"; then
      REASON="Delegator's collateral cannot cover this borrow amount"
    elif echo "$TX_OUTPUT" | grep -qi "HEALTH_FACTOR_LOWER"; then
      REASON="Borrow would drop the delegator's health factor below liquidation threshold"
    elif echo "$TX_OUTPUT" | grep -qE '0x4e487b71|Panic.*0x11'; then
      REASON="Arithmetic overflow — likely insufficient collateral or invalid borrow parameters"
    fi
    # Always carry the raw output; a guessed reason without it is unactionable.
    if [ -n "$REASON" ]; then
      echo -e "${RED}✗ BORROW_REVERTED: $REASON${NC}"
      echo "  Raw: $TX_OUTPUT"
    else
      echo -e "${RED}✗ BORROW_REVERTED: $TX_OUTPUT${NC}"
    fi
  else
    echo -e "${RED}✗ BORROW_FAILED: $TX_OUTPUT${NC}"
  fi
  exit 1
fi

# The borrow has already landed on-chain at this point — cast exited 0. Parsing
# must never be allowed to look like failure: `2>&1` above merges cast's stderr
# warnings into TX_OUTPUT, which breaks jq, and under `set -e` an unguarded
# top-level assignment would then kill the script with no output at all. An
# agent reads that as "the borrow failed" and retries, doubling the debt.
if ! TX_HASH=$(printf '%s' "$TX_OUTPUT" | jq -r '.transactionHash // .hash // empty' 2>/dev/null); then
  echo -e "${RED}✗ BORROW_SENT_BUT_UNPARSEABLE: the borrow was submitted successfully"
  echo -e "  but its receipt could not be parsed. DO NOT RETRY.${NC}"
  echo "  Raw output: $TX_OUTPUT"
  echo "  Verify the delegator's debt with: ./aave-status.sh $SYMBOL"
  exit 1
fi

# Only an explicit failure status is treated as a revert; cast versions that
# omit the field leave this empty and fall through.
TX_STATUS=$(printf '%s' "$TX_OUTPUT" | jq -r '.status // empty' 2>/dev/null || echo "")
if [ "$TX_STATUS" = "0x0" ] || [ "$TX_STATUS" = "0" ]; then
  echo -e "${RED}✗ BORROW_REVERTED: transaction $TX_HASH was mined but reverted${NC}"
  echo "  No debt was created and no tokens were received. Gas was still spent."
  exit 1
fi

if [ -n "$TX_HASH" ]; then
  echo -e "${GREEN}✓ Borrow successful!${NC}"
  echo "  TX: $TX_HASH"
  echo "  Amount: $AMOUNT $SYMBOL"
  echo "  Tokens sent to: $AGENT_ADDR"
  echo "  Debt charged to: $DELEGATOR"
  
  NEW_BALANCE_RAW=$(cast call "$ASSET_ADDR" \
    "balanceOf(address)(uint256)" \
    "$AGENT_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
  NEW_BALANCE_RAW=$(echo "$NEW_BALANCE_RAW" | strip_cast)
  if [ "$NEW_BALANCE_RAW" != "?" ]; then
    NEW_BALANCE=$(from_units "$NEW_BALANCE_RAW" "$DECIMALS")
    echo "  Agent $SYMBOL balance: $NEW_BALANCE"
  fi
  
  NEW_ACCOUNT=$(cast call "$POOL" \
    "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  if [ -n "$NEW_ACCOUNT" ]; then
    NEW_HF_RAW=$(echo "$NEW_ACCOUNT" | sed -n '6p' | strip_cast)
    if [ "$NEW_HF_RAW" != "$MAX_UINT" ]; then
      NEW_HF=$(hf_from_raw "$NEW_HF_RAW")
      echo "  New health factor: $NEW_HF"
    fi
  fi
else
  echo -e "${RED}✗ Borrow may have failed. Check transaction status manually.${NC}"
  exit 1
fi
