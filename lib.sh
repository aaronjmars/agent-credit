#!/usr/bin/env bash
# lib.sh — helpers shared by the aave-*.sh scripts.
#
# Sourced relative to the sourcing script's own directory, NOT $SKILL_DIR:
# SKILL_DIR points at the config directory, which is a different place (the
# test harness sets it to a temp dir).
#
#   # shellcheck source=./lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# This file is only ever sourced, so the constants below are consumed by the
# sourcing script and look unused when this file is linted on its own.
# shellcheck disable=SC2034

# Where config.json lives. SKILL_DIR is the one knob that relocates it; the
# scripts themselves never hardcode the path.
SKILL_DIR="${SKILL_DIR:-$HOME/.openclaw/skills/aave-delegation}"
CONFIG="$SKILL_DIR/config.json"

# Strip cast's bracket annotations e.g. "7920000000000000 [7.92e15]" → "7920000000000000"
strip_cast() { sed 's/ *\[.*\]//' | tr -d ' '; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# type(uint256).max. Aave returns this as the health factor when the account
# has no debt, and repay accepts it to mean "settle the exact debt".
MAX_UINT="115792089237316195423570985008687907853269984665640564039457584007913129639935"

# Aave scales the health factor by 1e18.
WAD="1000000000000000000"

# Aave's price oracle denominates everything in a single base currency with a
# fixed number of decimals. That is USD/8 on every market this skill targets;
# some deployments (the original V2 ETH market, a few L2 variants) use ETH/18,
# for which you export AAVE_BASE_CURRENCY_DECIMALS=18. Only the `~$X` display
# values depend on getting this right — both sides of every safety inequality
# are in base-currency units, so the checks hold either way.
#
# Sets BASE_CURRENCY_DECIMALS and BASE_CURRENCY_UNIT.
init_base_currency() {
  BASE_CURRENCY_DECIMALS="${AAVE_BASE_CURRENCY_DECIMALS:-8}"
  BASE_CURRENCY_UNIT=$(echo "10^$BASE_CURRENCY_DECIMALS" | bc)
}

# to_usd <amount-in-base-currency> — display only, 2dp.
to_usd() { echo "scale=2; $1 / $BASE_CURRENCY_UNIT" | bc; }

# hf_from_raw <health-factor-at-1e18> — 4dp. Callers must handle MAX_UINT
# themselves before calling; the sentinel's display differs per script.
hf_from_raw() { echo "scale=4; $1 / $WAD" | bc; }

# from_units <raw> <decimals> — raw integer to human amount.
from_units() { echo "scale=$2; $1 / (10^$2)" | bc; }

# to_units <human> <decimals> — human amount to raw integer. Truncates rather
# than rounds, which is the safe direction: never borrow or repay more than
# was asked for.
to_units() { echo "$1 * (10^$2)" | bc | cut -d'.' -f1; }

# require_config — abort with a pointer to setup if config.json is absent.
# Reads $CONFIG.
require_config() {
  if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}✗ CONFIG_NOT_FOUND: no config at $CONFIG${NC}" >&2
    echo "  Run ./aave-setup.sh, or set SKILL_DIR to the directory holding config.json." >&2
    exit 1
  fi
}

# load_config — read the connection fields every script needs, letting AAVE_*
# env vars win. Sets RPC_URL, AGENT_PK, DELEGATOR, POOL, DATA_PROVIDER, CHAIN.
#
# `// empty` matters: without it a missing key yields the literal string
# "null", which then gets handed to cast as an address or URL and fails with
# an opaque error instead of a config one.
load_config() {
  require_config
  RPC_URL="${AAVE_RPC_URL:-$(jq -r '.rpcUrl // empty' "$CONFIG")}"
  AGENT_PK="${AAVE_AGENT_PRIVATE_KEY:-$(jq -r '.agentPrivateKey // empty' "$CONFIG")}"
  DELEGATOR="${AAVE_DELEGATOR_ADDRESS:-$(jq -r '.delegatorAddress // empty' "$CONFIG")}"
  POOL="${AAVE_POOL_ADDRESS:-$(jq -r '.poolAddress // empty' "$CONFIG")}"
  DATA_PROVIDER=$(jq -r '.dataProviderAddress // empty' "$CONFIG")
  CHAIN=$(jq -r '.chain // "unknown"' "$CONFIG")

  local missing=""
  [ -z "$RPC_URL" ]       && missing="$missing rpcUrl"
  [ -z "$AGENT_PK" ]      && missing="$missing agentPrivateKey"
  [ -z "$DELEGATOR" ]     && missing="$missing delegatorAddress"
  [ -z "$POOL" ]          && missing="$missing poolAddress"
  [ -z "$DATA_PROVIDER" ] && missing="$missing dataProviderAddress"
  if [ -n "$missing" ]; then
    echo -e "${RED}✗ INVALID_CONFIG: missing required field(s):$missing${NC}" >&2
    echo "  Fill them in at $CONFIG (see config.example.json)." >&2
    exit 1
  fi
}

# resolve_asset <SYMBOL> — look up one asset and abort if it is unusable.
# Sets ASSET_ADDR and DECIMALS.
#
# DECIMALS is validated because bc reads an empty or non-numeric scale as 0,
# which would divide by 10^0 and silently treat a raw wei value as a human
# amount.
resolve_asset() {
  local symbol="$1"
  ASSET_ADDR=$(jq -r ".assets[\"$symbol\"].address // empty" "$CONFIG")
  DECIMALS=$(jq -r ".assets[\"$symbol\"].decimals // empty" "$CONFIG")

  if [ -z "$ASSET_ADDR" ]; then
    echo -e "${RED}✗ Asset $symbol not found in config${NC}" >&2
    exit 1
  fi
  if ! [[ "$DECIMALS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}✗ Asset $symbol has missing or non-numeric 'decimals' in config${NC}" >&2
    exit 1
  fi
}

# resolve_var_debt_token <asset-addr> — third return value of
# getReserveTokensAddresses. Echoes the address.
#
# The zero-address check matters: an asset that is not listed on this pool
# returns the zero address here, and the subsequent allowance call against it
# would fail with a raw cast error rather than a usable diagnostic.
resolve_var_debt_token() {
  local asset_addr="$1" tokens vdt
  if ! tokens=$(cast call "$DATA_PROVIDER" \
      "getReserveTokensAddresses(address)(address,address,address)" \
      "$asset_addr" --rpc-url "$RPC_URL" 2>&1); then
    echo -e "${RED}✗ Could not resolve debt tokens for $asset_addr — $tokens${NC}" >&2
    return 1
  fi
  vdt=$(echo "$tokens" | sed -n '3p' | strip_cast)
  if [ -z "$vdt" ] || [ "$vdt" = "0x0000000000000000000000000000000000000000" ]; then
    echo -e "${RED}✗ No variable debt token for $asset_addr — is the asset listed on this pool?${NC}" >&2
    return 1
  fi
  printf '%s\n' "$vdt"
}
