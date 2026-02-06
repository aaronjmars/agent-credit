#!/usr/bin/env bash
# aave-status.sh — Check delegation allowance, health factor, and debt
# Usage: aave-status.sh [SYMBOL] [--health-only] [--json]
set -euo pipefail

# Strip cast's bracket annotations e.g. "7920000000000000 [7.92e15]" → "7920000000000000"
strip_cast() { sed 's/ *\[.*\]//' | tr -d ' '; }

SKILL_DIR="${SKILL_DIR:-$HOME/.openclaw/skills/aave-delegation}"
CONFIG="$SKILL_DIR/config.json"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
SYMBOL=""
HEALTH_ONLY=false
JSON_OUTPUT=false
for arg in "$@"; do
  case "$arg" in
    --health-only) HEALTH_ONLY=true ;;
    --json) JSON_OUTPUT=true ;;
    *) SYMBOL="$arg" ;;
  esac
done

# Load config
RPC_URL="${AAVE_RPC_URL:-$(jq -r '.rpcUrl' "$CONFIG")}"
AGENT_PK="${AAVE_AGENT_PRIVATE_KEY:-$(jq -r '.agentPrivateKey' "$CONFIG")}"
DELEGATOR="${AAVE_DELEGATOR_ADDRESS:-$(jq -r '.delegatorAddress' "$CONFIG")}"
POOL="${AAVE_POOL_ADDRESS:-$(jq -r '.poolAddress' "$CONFIG")}"
DATA_PROVIDER=$(jq -r '.dataProviderAddress' "$CONFIG")
AGENT_ADDR=$(cast wallet address "$AGENT_PK")

# === Health Factor ===
ACCOUNT_DATA=$(cast call "$POOL" \
  "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
  "$DELEGATOR" \
  --rpc-url "$RPC_URL")

TOTAL_COLLATERAL=$(echo "$ACCOUNT_DATA" | sed -n '1p' | strip_cast)
TOTAL_DEBT=$(echo "$ACCOUNT_DATA" | sed -n '2p' | strip_cast)
AVAILABLE_BORROWS=$(echo "$ACCOUNT_DATA" | sed -n '3p' | strip_cast)
CURRENT_LT=$(echo "$ACCOUNT_DATA" | sed -n '4p' | strip_cast)
LTV=$(echo "$ACCOUNT_DATA" | sed -n '5p' | strip_cast)
HEALTH_FACTOR_RAW=$(echo "$ACCOUNT_DATA" | sed -n '6p' | strip_cast)

COLLATERAL_USD=$(echo "scale=2; $TOTAL_COLLATERAL / 100000000" | bc)
DEBT_USD=$(echo "scale=2; $TOTAL_DEBT / 100000000" | bc)
AVAILABLE_USD=$(echo "scale=2; $AVAILABLE_BORROWS / 100000000" | bc)

MAX_UINT="115792089237316195423570985008687907853269984665640564039457584007913129639935"
if [ "$HEALTH_FACTOR_RAW" = "$MAX_UINT" ]; then
  HF="inf"
  HF_DISPLAY="∞ (no debt)"
else
  HF=$(echo "scale=4; $HEALTH_FACTOR_RAW / 1000000000000000000" | bc)
  HF_DISPLAY="$HF"
fi

if [ "$HEALTH_ONLY" = true ]; then
  if [ "$JSON_OUTPUT" = true ]; then
    echo "{\"healthFactor\": \"$HF\", \"collateralUsd\": \"$COLLATERAL_USD\", \"debtUsd\": \"$DEBT_USD\", \"availableBorrowsUsd\": \"$AVAILABLE_USD\"}"
  else
    echo "Health Factor: $HF_DISPLAY"
    echo "Collateral: \$$COLLATERAL_USD"
    echo "Debt: \$$DEBT_USD"
    echo "Available to borrow: \$$AVAILABLE_USD"
  fi
  exit 0
fi

# === Full Status ===
if [ "$JSON_OUTPUT" != true ]; then
  echo "=== Aave V3 Delegation Status ==="
  echo ""
  echo "--- Delegator: $DELEGATOR ---"
  echo "  Collateral:       \$$COLLATERAL_USD"
  echo "  Debt:             \$$DEBT_USD"
  echo "  Available borrow: \$$AVAILABLE_USD"
  echo "  Health factor:    $HF_DISPLAY"
  echo ""
  echo "--- Agent: $AGENT_ADDR ---"
  AGENT_BALANCE=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC_URL")
  AGENT_ETH=$(cast from-wei "$AGENT_BALANCE")
  echo "  Native balance:   $AGENT_ETH"
  echo ""
fi

# === Per-Asset Delegation & Debt ===
if [ -n "$SYMBOL" ]; then
  ASSETS="$SYMBOL"
else
  ASSETS=$(jq -r '.assets | keys | .[]' "$CONFIG")
fi

JSON_ASSETS="[]"

for SYM in $ASSETS; do
  ASSET_ADDR=$(jq -r ".assets[\"$SYM\"].address" "$CONFIG")
  DECIMALS=$(jq -r ".assets[\"$SYM\"].decimals" "$CONFIG")
  
  if [ "$ASSET_ADDR" = "null" ] || [ -z "$ASSET_ADDR" ]; then
    echo "  ⚠ $SYM: not found in config"
    continue
  fi

  # Get debt token addresses
  TOKENS=$(cast call "$DATA_PROVIDER" \
    "getReserveTokensAddresses(address)(address,address,address)" \
    "$ASSET_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  
  VAR_DEBT_TOKEN=$(echo "$TOKENS" | sed -n '3p' | strip_cast)

  # Delegation allowance
  ALLOWANCE_RAW=$(cast call "$VAR_DEBT_TOKEN" \
    "borrowAllowance(address,address)(uint256)" \
    "$DELEGATOR" "$AGENT_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
  ALLOWANCE_RAW=$(echo "$ALLOWANCE_RAW" | strip_cast)
  ALLOWANCE=$(echo "scale=$DECIMALS; $ALLOWANCE_RAW / (10^$DECIMALS)" | bc)

  # Current debt on this asset
  DEBT_RAW=$(cast call "$VAR_DEBT_TOKEN" \
    "balanceOf(address)(uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
  DEBT_RAW=$(echo "$DEBT_RAW" | strip_cast)
  DEBT=$(echo "scale=$DECIMALS; $DEBT_RAW / (10^$DECIMALS)" | bc)

  # Agent's token balance
  AGENT_TOKEN_RAW=$(cast call "$ASSET_ADDR" \
    "balanceOf(address)(uint256)" \
    "$AGENT_ADDR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
  AGENT_TOKEN_RAW=$(echo "$AGENT_TOKEN_RAW" | strip_cast)
  AGENT_TOKEN=$(echo "scale=$DECIMALS; $AGENT_TOKEN_RAW / (10^$DECIMALS)" | bc)

  if [ "$JSON_OUTPUT" = true ]; then
    JSON_ASSETS=$(echo "$JSON_ASSETS" | jq --arg sym "$SYM" --arg allow "$ALLOWANCE" \
      --arg debt "$DEBT" --arg agent_bal "$AGENT_TOKEN" --arg vdt "$VAR_DEBT_TOKEN" \
      '. += [{"symbol": $sym, "allowance": $allow, "delegatorDebt": $debt, "agentBalance": $agent_bal, "variableDebtToken": $vdt}]')
  else
    echo "--- $SYM ---"
    echo "  Delegation allowance: $ALLOWANCE $SYM"
    echo "  Delegator debt:       $DEBT $SYM"
    echo "  Agent balance:        $AGENT_TOKEN $SYM"
    echo "  VariableDebtToken:    $VAR_DEBT_TOKEN"
    echo ""
  fi
done

if [ "$JSON_OUTPUT" = true ]; then
  jq -n \
    --arg hf "$HF" \
    --arg collateral "$COLLATERAL_USD" \
    --arg debt "$DEBT_USD" \
    --arg available "$AVAILABLE_USD" \
    --arg agent "$AGENT_ADDR" \
    --arg delegator "$DELEGATOR" \
    --argjson assets "$JSON_ASSETS" \
    '{
      delegator: $delegator,
      agent: $agent,
      healthFactor: $hf,
      collateralUsd: $collateral,
      debtUsd: $debt,
      availableBorrowsUsd: $available,
      assets: $assets
    }'
fi
