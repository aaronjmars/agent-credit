#!/usr/bin/env bash
# aave-borrow.sh — Borrow from Aave V3 via credit delegation
# Usage: aave-borrow.sh <SYMBOL> <AMOUNT>
# Example: aave-borrow.sh USDC 100
set -euo pipefail

SKILL_DIR="${SKILL_DIR:-$HOME/.openclaw/skills/aave-delegation}"
CONFIG="$SKILL_DIR/config.json"

# Strip cast's bracket annotations e.g. "7920000000000000 [7.92e15]" → "7920000000000000"
strip_cast() { sed 's/ *\[.*\]//' | tr -d ' '; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === Parse arguments ===
if [ $# -lt 2 ]; then
  echo "Usage: aave-borrow.sh <SYMBOL> <AMOUNT>"
  echo "Example: aave-borrow.sh USDC 100"
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

# Convert human amount to raw (e.g., 100 USDC → 100000000)
AMOUNT_RAW=$(echo "$AMOUNT * (10^$DECIMALS)" | bc | cut -d'.' -f1)

# Safety config
MIN_HF="${AAVE_MIN_HEALTH_FACTOR:-$(jq -r '.safety.minHealthFactor // "1.5"' "$CONFIG")}"
MAX_BORROW=$(jq -r '.safety.maxBorrowPerTx // "1000"' "$CONFIG")
MAX_BORROW_UNIT=$(jq -r '.safety.maxBorrowPerTxUnit // "USDC"' "$CONFIG")

echo "=== Aave V3 Credit Delegation Borrow ==="
echo "  Chain:      $CHAIN"
echo "  Asset:      $SYMBOL ($ASSET_ADDR)"
echo "  Amount:     $AMOUNT $SYMBOL ($AMOUNT_RAW raw)"
echo "  Delegator:  $DELEGATOR"
echo "  Agent:      $AGENT_ADDR"
echo "  Pool:       $POOL"
echo ""

# === SAFETY CHECK 1: Per-transaction cap ===
echo "--- Safety Check 1: Transaction Cap ---"
# Simple check — if same unit, compare directly
if [ "$SYMBOL" = "$MAX_BORROW_UNIT" ]; then
  if (( $(echo "$AMOUNT > $MAX_BORROW" | bc -l) )); then
    echo -e "${RED}✗ AMOUNT_EXCEEDS_CAP: $AMOUNT $SYMBOL exceeds max $MAX_BORROW $MAX_BORROW_UNIT per tx${NC}"
    echo "  Update safety.maxBorrowPerTx in config to increase limit."
    exit 1
  fi
fi
echo -e "${GREEN}✓${NC} Amount within per-tx cap ($MAX_BORROW $MAX_BORROW_UNIT)"

# === SAFETY CHECK 2: Delegation allowance ===
echo "--- Safety Check 2: Delegation Allowance ---"

# Resolve variable debt token
TOKENS=$(cast call "$DATA_PROVIDER" \
  "getReserveTokensAddresses(address)(address,address,address)" \
  "$ASSET_ADDR" \
  --rpc-url "$RPC_URL")
VAR_DEBT_TOKEN=$(echo "$TOKENS" | sed -n '3p' | strip_cast)

ALLOWANCE_RAW=$(cast call "$VAR_DEBT_TOKEN" \
  "borrowAllowance(address,address)(uint256)" \
  "$DELEGATOR" "$AGENT_ADDR" \
  --rpc-url "$RPC_URL")
ALLOWANCE_RAW=$(echo "$ALLOWANCE_RAW" | strip_cast)
ALLOWANCE=$(echo "scale=$DECIMALS; $ALLOWANCE_RAW / (10^$DECIMALS)" | bc)

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
HEALTH_FACTOR_RAW=$(echo "$ACCOUNT_DATA" | sed -n '6p' | strip_cast)

MAX_UINT="115792089237316195423570985008687907853269984665640564039457584007913129639935"
if [ "$HEALTH_FACTOR_RAW" = "$MAX_UINT" ]; then
  HF="999"  # effectively infinite
  HF_DISPLAY="∞ (no current debt)"
else
  HF=$(echo "scale=4; $HEALTH_FACTOR_RAW / 1000000000000000000" | bc)
  HF_DISPLAY="$HF"
fi

COLLATERAL_USD=$(echo "scale=2; $TOTAL_COLLATERAL / 100000000" | bc)
DEBT_USD=$(echo "scale=2; $TOTAL_DEBT / 100000000" | bc)

echo "  Current HF:     $HF_DISPLAY"
echo "  Collateral:     \$$COLLATERAL_USD"
echo "  Existing debt:  \$$DEBT_USD"

# Check current HF is above minimum
if (( $(echo "$HF < $MIN_HF" | bc -l) )) && [ "$HF" != "999" ]; then
  echo -e "${RED}✗ HEALTH_FACTOR_TOO_LOW: Current HF ($HF) is already below minimum ($MIN_HF)${NC}"
  echo "  Delegator should add collateral or repay debt before agent borrows more."
  exit 1
fi

# Check available borrows
if [ "$AVAILABLE_BORROWS" = "0" ]; then
  echo -e "${RED}✗ No available borrowing capacity for delegator${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Health factor OK: $HF_DISPLAY (minimum: $MIN_HF)"

# === SAFETY CHECK 4: Agent has enough gas ===
echo "--- Safety Check 4: Gas Balance ---"
AGENT_BALANCE=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC_URL")
AGENT_ETH=$(cast from-wei "$AGENT_BALANCE")
# Aave borrow tx uses ~300k-500k gas. Estimate cost conservatively.
GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
MIN_GAS_WEI=$(echo "$GAS_PRICE * 500000" | bc)

if [ "$AGENT_BALANCE" = "0" ]; then
  echo -e "${RED}✗ INSUFFICIENT_GAS: Agent wallet has 0 ETH${NC}"
  echo "  Send at least 0.001 ETH to $AGENT_ADDR on $CHAIN for gas."
  exit 1
elif (( $(echo "$AGENT_BALANCE < $MIN_GAS_WEI" | bc) )); then
  MIN_GAS_ETH=$(cast from-wei "$MIN_GAS_WEI")
  echo -e "${RED}✗ INSUFFICIENT_GAS: Agent has $AGENT_ETH ETH but needs ~$MIN_GAS_ETH ETH for gas${NC}"
  echo "  Send at least 0.001 ETH to $AGENT_ADDR on $CHAIN."
  exit 1
fi
echo -e "${GREEN}✓${NC} Agent gas balance: $AGENT_ETH ETH"

# === EXECUTE BORROW ===
echo ""
echo "=== Executing Borrow ==="
echo "  Pool.borrow($ASSET_ADDR, $AMOUNT_RAW, 2, 0, $DELEGATOR)"
echo ""

# interestRateMode: 2 = variable rate
# referralCode: 0 (inactive)
# onBehalfOf: delegator address (debt goes to them)
TX_OUTPUT=$(cast send "$POOL" \
  "borrow(address,uint256,uint256,uint16,address)" \
  "$ASSET_ADDR" \
  "$AMOUNT_RAW" \
  2 \
  0 \
  "$DELEGATOR" \
  --private-key "$AGENT_PK" \
  --rpc-url "$RPC_URL" \
  --gas-limit 500000 \
  --json 2>&1)
TX_EXIT=$?

if [ $TX_EXIT -ne 0 ]; then
  # Parse common errors into human-readable messages
  if echo "$TX_OUTPUT" | grep -qi "insufficient funds"; then
    echo -e "${RED}✗ INSUFFICIENT_GAS: Agent wallet can't afford gas for this transaction.${NC}"
    echo "  Send more ETH to $AGENT_ADDR on $CHAIN."
  elif echo "$TX_OUTPUT" | grep -qi "revert"; then
    # Decode Aave-specific revert reasons
    REASON="$TX_OUTPUT"
    if echo "$TX_OUTPUT" | grep -q "0x11"; then
      REASON="Arithmetic overflow — likely insufficient collateral or invalid borrow parameters"
    elif echo "$TX_OUTPUT" | grep -qi "BORROWING_NOT_ENABLED"; then
      REASON="Borrowing is not enabled for $SYMBOL on this pool"
    elif echo "$TX_OUTPUT" | grep -qi "COLLATERAL_CANNOT_COVER"; then
      REASON="Delegator's collateral cannot cover this borrow amount"
    elif echo "$TX_OUTPUT" | grep -qi "HEALTH_FACTOR_LOWER"; then
      REASON="Borrow would drop the delegator's health factor below liquidation threshold"
    fi
    echo -e "${RED}✗ BORROW_REVERTED: $REASON${NC}"
  else
    echo -e "${RED}✗ BORROW_FAILED: $TX_OUTPUT${NC}"
  fi
  exit 1
fi

TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // .hash // empty' 2>/dev/null)

if [ -n "$TX_HASH" ]; then
  echo -e "${GREEN}✓ Borrow successful!${NC}"
  echo "  TX: $TX_HASH"
  echo "  Amount: $AMOUNT $SYMBOL"
  echo "  Tokens sent to: $AGENT_ADDR"
  echo "  Debt charged to: $DELEGATOR"
  
  # Verify new balance
  NEW_BALANCE_RAW=$(cast call "$ASSET_ADDR" \
    "balanceOf(address)(uint256)" \
    "$AGENT_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "?")
  NEW_BALANCE_RAW=$(echo "$NEW_BALANCE_RAW" | strip_cast)
  if [ "$NEW_BALANCE_RAW" != "?" ]; then
    NEW_BALANCE=$(echo "scale=$DECIMALS; $NEW_BALANCE_RAW / (10^$DECIMALS)" | bc)
    echo "  Agent $SYMBOL balance: $NEW_BALANCE"
  fi
  
  # Check new health factor
  NEW_ACCOUNT=$(cast call "$POOL" \
    "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  if [ -n "$NEW_ACCOUNT" ]; then
    NEW_HF_RAW=$(echo "$NEW_ACCOUNT" | sed -n '6p' | strip_cast)
    if [ "$NEW_HF_RAW" != "$MAX_UINT" ]; then
      NEW_HF=$(echo "scale=4; $NEW_HF_RAW / 1000000000000000000" | bc)
      echo "  New health factor: $NEW_HF"
    fi
  fi
else
  echo -e "${RED}✗ Borrow may have failed. Check transaction status manually.${NC}"
  exit 1
fi
