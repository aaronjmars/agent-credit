#!/usr/bin/env bash
# aave-status.sh — Check delegation allowance, health factor, and debt
# Usage: aave-status.sh [SYMBOL] [--health-only] [--json]
set -euo pipefail

# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Parse args
SYMBOL=""
HEALTH_ONLY=false
JSON_OUTPUT=false
for arg in "$@"; do
  case "$arg" in
    --health-only) HEALTH_ONLY=true ;;
    --json) JSON_OUTPUT=true ;;
    # Without this, a typo'd flag is silently taken as the asset symbol and
    # the caller gets human-readable text where it asked for JSON.
    -*) echo "Unknown flag: $arg" >&2
        echo "Usage: aave-status.sh [SYMBOL] [--health-only] [--json]" >&2
        exit 1 ;;
    *) SYMBOL="$arg" ;;
  esac
done

# Load config
load_config
AGENT_ADDR=$(cast wallet address "$AGENT_PK")
init_base_currency

# === Health Factor ===
ACCOUNT_DATA=$(cast call "$POOL" \
  "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
  "$DELEGATOR" \
  --rpc-url "$RPC_URL")

TOTAL_COLLATERAL=$(echo "$ACCOUNT_DATA" | sed -n '1p' | strip_cast)
TOTAL_DEBT=$(echo "$ACCOUNT_DATA" | sed -n '2p' | strip_cast)
AVAILABLE_BORROWS=$(echo "$ACCOUNT_DATA" | sed -n '3p' | strip_cast)
HEALTH_FACTOR_RAW=$(echo "$ACCOUNT_DATA" | sed -n '6p' | strip_cast)

COLLATERAL_USD=$(to_usd "$TOTAL_COLLATERAL")
DEBT_USD=$(to_usd "$TOTAL_DEBT")
AVAILABLE_USD=$(to_usd "$AVAILABLE_BORROWS")

if [ "$HEALTH_FACTOR_RAW" = "$MAX_UINT" ]; then
  HF="inf"
  HF_DISPLAY="∞ (no debt)"
else
  HF=$(hf_from_raw "$HEALTH_FACTOR_RAW")
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
# Assets skipped because something could not be read. Reported as a non-zero
# exit so a caller can tell a partial report from a complete one.
RPC_ERRORS=0

for SYM in $ASSETS; do
  ASSET_ADDR=$(jq -r ".assets[\"$SYM\"].address // empty" "$CONFIG")
  DECIMALS=$(jq -r ".assets[\"$SYM\"].decimals // empty" "$CONFIG")

  if [ -z "$ASSET_ADDR" ]; then
    echo "  ⚠ $SYM: not found in config" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi
  # bc reads an empty or non-numeric scale as 0, which would divide by 10^0 and
  # print the raw integer as though it were the human amount.
  if ! [[ "$DECIMALS" =~ ^[0-9]+$ ]]; then
    echo "  ⚠ $SYM: missing or non-numeric 'decimals' in config" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi

  # Every read below reports a number an agent may act on, so a failed read
  # must never be defaulted into one. Previously these fell back to "0": a
  # single failed lookup cascaded into allowance/debt/balance all reading 0,
  # and --json emitted "delegatorDebt":"0" with exit 0 — indistinguishable
  # from a genuinely settled loan, which is what tells an agent to skip a
  # repayment that is actually due.
  if ! TOKENS=$(cast call "$DATA_PROVIDER" \
      "getReserveTokensAddresses(address)(address,address,address)" \
      "$ASSET_ADDR" \
      --rpc-url "$RPC_URL" 2>&1); then
    echo "  ✗ $SYM: could not resolve debt tokens — $TOKENS" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi
  VAR_DEBT_TOKEN=$(echo "$TOKENS" | sed -n '3p' | strip_cast)

  if ! ALLOWANCE_RAW=$(cast call "$VAR_DEBT_TOKEN" \
      "borrowAllowance(address,address)(uint256)" \
      "$DELEGATOR" "$AGENT_ADDR" \
      --rpc-url "$RPC_URL" 2>&1); then
    echo "  ✗ $SYM: could not read delegation allowance — $ALLOWANCE_RAW" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi
  ALLOWANCE_RAW=$(echo "$ALLOWANCE_RAW" | strip_cast)
  ALLOWANCE=$(from_units "$ALLOWANCE_RAW" "$DECIMALS")

  if ! DEBT_RAW=$(cast call "$VAR_DEBT_TOKEN" \
      "balanceOf(address)(uint256)" \
      "$DELEGATOR" \
      --rpc-url "$RPC_URL" 2>&1); then
    echo "  ✗ $SYM: could not read delegator debt — $DEBT_RAW" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi
  DEBT_RAW=$(echo "$DEBT_RAW" | strip_cast)
  DEBT=$(from_units "$DEBT_RAW" "$DECIMALS")

  if ! AGENT_TOKEN_RAW=$(cast call "$ASSET_ADDR" \
      "balanceOf(address)(uint256)" \
      "$AGENT_ADDR" \
      --rpc-url "$RPC_URL" 2>&1); then
    echo "  ✗ $SYM: could not read agent balance — $AGENT_TOKEN_RAW" >&2
    RPC_ERRORS=$((RPC_ERRORS + 1))
    continue
  fi
  AGENT_TOKEN_RAW=$(echo "$AGENT_TOKEN_RAW" | strip_cast)
  AGENT_TOKEN=$(from_units "$AGENT_TOKEN_RAW" "$DECIMALS")

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

# Exit non-zero on a partial report. A caller that acts on "no debt" must be
# able to distinguish that from "could not read the debt".
if [ "$RPC_ERRORS" -gt 0 ]; then
  echo "✗ $RPC_ERRORS asset(s) could not be read; this report is incomplete." >&2
  exit 1
fi
