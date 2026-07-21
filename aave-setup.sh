#!/usr/bin/env bash
# aave-setup.sh — Verify skill configuration and dependencies
set -euo pipefail

# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }

# This script deliberately does NOT use lib.sh's load_config: that aborts on
# the first missing field, whereas setup's whole job is to report every
# problem at once.
ERRORS=0

echo "=== Aave Delegation Skill Setup Check ==="
echo ""

# 1. Check dependencies
echo "--- Dependencies ---"
for bin in cast jq bc; do
  if command -v "$bin" &>/dev/null; then
    ok "$bin found: $(command -v "$bin")"
  else
    fail "$bin not found. Install it first."
    ERRORS=$((ERRORS + 1))
  fi
done

# 2. Check config file
echo ""
echo "--- Configuration ---"
if [ ! -f "$CONFIG" ]; then
  fail "Config not found at $CONFIG"
  echo "  Create it with: mkdir -p $SKILL_DIR && cp config.example.json $CONFIG"
  exit 1
fi
ok "Config found: $CONFIG"

# 3. Validate config fields
RPC_URL=$(jq -r '.rpcUrl // empty' "$CONFIG")
RPC_URL="${AAVE_RPC_URL:-$RPC_URL}"
if [ -z "$RPC_URL" ]; then
  fail "rpcUrl not set in config or AAVE_RPC_URL"
  ERRORS=$((ERRORS + 1))
else
  ok "RPC URL: $RPC_URL"
fi

AGENT_PK=$(jq -r '.agentPrivateKey // empty' "$CONFIG")
AGENT_PK="${AAVE_AGENT_PRIVATE_KEY:-$AGENT_PK}"
if [ -z "$AGENT_PK" ]; then
  fail "agentPrivateKey not set"
  ERRORS=$((ERRORS + 1))
else
  ok "Agent private key: configured (hidden)"
fi

DELEGATOR=$(jq -r '.delegatorAddress // empty' "$CONFIG")
DELEGATOR="${AAVE_DELEGATOR_ADDRESS:-$DELEGATOR}"
if [ -z "$DELEGATOR" ]; then
  fail "delegatorAddress not set"
  ERRORS=$((ERRORS + 1))
else
  ok "Delegator address: $DELEGATOR"
fi

POOL=$(jq -r '.poolAddress // empty' "$CONFIG")
POOL="${AAVE_POOL_ADDRESS:-$POOL}"
if [ -z "$POOL" ]; then
  fail "poolAddress not set"
  ERRORS=$((ERRORS + 1))
else
  ok "Pool address: $POOL"
fi

DATA_PROVIDER=$(jq -r '.dataProviderAddress // empty' "$CONFIG")
if [ -z "$DATA_PROVIDER" ]; then
  warn "dataProviderAddress not set (needed for debt token resolution)"
else
  ok "DataProvider address: $DATA_PROVIDER"
fi

init_base_currency

# 4. Check RPC connectivity
echo ""
echo "--- Network ---"
if [ -n "$RPC_URL" ]; then
  CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  if [ -n "$CHAIN_ID" ]; then
    ok "RPC connected. Chain ID: $CHAIN_ID"
  else
    fail "Cannot connect to RPC at $RPC_URL"
    ERRORS=$((ERRORS + 1))
  fi
fi

# 5. Check agent wallet
echo ""
echo "--- Agent Wallet ---"
if [ -n "$AGENT_PK" ] && [ -n "$RPC_URL" ]; then
  AGENT_ADDR=$(cast wallet address "$AGENT_PK" 2>/dev/null || echo "")
  if [ -n "$AGENT_ADDR" ]; then
    ok "Agent address: $AGENT_ADDR"
    BALANCE=$(cast balance "$AGENT_ADDR" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    BALANCE_ETH=$(cast from-wei "$BALANCE" 2>/dev/null || echo "0")
    if [ "$BALANCE" = "0" ]; then
      warn "Agent wallet has 0 native token — needs gas to execute transactions"
    else
      ok "Agent balance: $BALANCE_ETH ETH (native)"
    fi
  else
    fail "Invalid private key"
    ERRORS=$((ERRORS + 1))
  fi
fi

# 6. Check Pool contract
echo ""
echo "--- Aave Pool ---"
if [ -n "$POOL" ] && [ -n "$RPC_URL" ]; then
  CODE=$(cast code "$POOL" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
  if [ "$CODE" = "0x" ] || [ -z "$CODE" ]; then
    fail "Pool address $POOL has no code — wrong address or wrong chain?"
    ERRORS=$((ERRORS + 1))
  else
    ok "Pool contract verified"
  fi
fi

# 7. Check delegation status for configured assets
echo ""
echo "--- Delegation Status ---"
if [ -n "$AGENT_PK" ] && [ -n "$RPC_URL" ] && [ -n "$DELEGATOR" ] && [ -n "$DATA_PROVIDER" ]; then
  AGENT_ADDR=$(cast wallet address "$AGENT_PK" 2>/dev/null)
  
  for SYMBOL in $(jq -r '.assets | keys[]' "$CONFIG" 2>/dev/null); do
    ASSET_ADDR=$(jq -r ".assets[\"$SYMBOL\"].address" "$CONFIG")
    DECIMALS=$(jq -r ".assets[\"$SYMBOL\"].decimals" "$CONFIG")
    
    TOKENS=$(cast call "$DATA_PROVIDER" \
      "getReserveTokensAddresses(address)(address,address,address)" \
      "$ASSET_ADDR" \
      --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    
    if [ -z "$TOKENS" ]; then
      warn "$SYMBOL: Could not resolve debt token addresses"
      continue
    fi
    
    # Parse variable debt token (3rd return value)
    VAR_DEBT_TOKEN=$(echo "$TOKENS" | sed -n '3p' | strip_cast)
    
    if [ -z "$VAR_DEBT_TOKEN" ] || [ "$VAR_DEBT_TOKEN" = "0x0000000000000000000000000000000000000000" ]; then
      warn "$SYMBOL: No variable debt token found"
      continue
    fi
    
    ALLOWANCE_RAW=$(cast call "$VAR_DEBT_TOKEN" \
      "borrowAllowance(address,address)(uint256)" \
      "$DELEGATOR" "$AGENT_ADDR" \
      --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    
    ALLOWANCE_RAW=$(echo "$ALLOWANCE_RAW" | strip_cast)
    
    if [ "$ALLOWANCE_RAW" = "0" ]; then
      warn "$SYMBOL: No delegation allowance — delegator must call approveDelegation()"
    else
      # The fallback shows the raw value labelled as raw. It previously fell
      # back to the bare integer, which read as a 10^decimals overstatement of
      # the delegation on the one screen used to confirm its size.
      ALLOWANCE=$(from_units "$ALLOWANCE_RAW" "$DECIMALS" 2>/dev/null || echo "?(raw $ALLOWANCE_RAW)")
      ok "$SYMBOL: Delegation allowance = $ALLOWANCE $SYMBOL (DebtToken: $VAR_DEBT_TOKEN)"
    fi
  done
fi

# 8. Check delegator health
echo ""
echo "--- Delegator Health ---"
if [ -n "$POOL" ] && [ -n "$RPC_URL" ] && [ -n "$DELEGATOR" ]; then
  ACCOUNT_DATA=$(cast call "$POOL" \
    "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
    "$DELEGATOR" \
    --rpc-url "$RPC_URL" 2>/dev/null || echo "")
  
  if [ -n "$ACCOUNT_DATA" ]; then
    TOTAL_COLLATERAL=$(echo "$ACCOUNT_DATA" | sed -n '1p' | strip_cast)
    TOTAL_DEBT=$(echo "$ACCOUNT_DATA" | sed -n '2p' | strip_cast)
    AVAILABLE_BORROWS=$(echo "$ACCOUNT_DATA" | sed -n '3p' | strip_cast)
    HEALTH_FACTOR_RAW=$(echo "$ACCOUNT_DATA" | sed -n '6p' | strip_cast)
    
    # Values are in base currency — usually USD/8-dec, override via AAVE_BASE_CURRENCY_DECIMALS
    COLLATERAL_USD=$(to_usd "$TOTAL_COLLATERAL" 2>/dev/null || echo "?")
    DEBT_USD=$(to_usd "$TOTAL_DEBT" 2>/dev/null || echo "?")
    AVAILABLE_USD=$(to_usd "$AVAILABLE_BORROWS" 2>/dev/null || echo "?")
    
    if [ "$HEALTH_FACTOR_RAW" = "$MAX_UINT" ]; then
      HF="∞ (no debt)"
    else
      HF=$(hf_from_raw "$HEALTH_FACTOR_RAW" 2>/dev/null || echo "?")
    fi
    
    ok "Collateral: \$$COLLATERAL_USD"
    ok "Debt: \$$DEBT_USD"
    ok "Available borrows: \$$AVAILABLE_USD"
    ok "Health factor: $HF"
  else
    warn "Could not read delegator account data"
  fi
fi

echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ]; then
  ok "All checks passed. Skill is ready."
else
  fail "$ERRORS error(s) found. Fix them before using the skill."
  exit 1
fi
