#!/usr/bin/env bash
# tests/test-borrow-contract.sh
#
# Contract-enforcement fixtures for aave-borrow.sh covering the two gaps
# closed in PR #5:
#
#   1. Cap-bypass: borrow WETH 1 against a `1000 USDC` cap must FAIL Check 1
#      (cross-asset cap binds via base-currency normalization).
#   2. HF-projection: a borrow that leaves *current* HF healthy but projected
#      HF below `minHealthFactor` must FAIL Check 3.
#
# Plus a positive sanity case (borrow within cap AND projected HF safe) that
# must reach the borrow-execute branch.
#
# Approach: prepend $PATH with tests/mocks/ which contains a stub `cast` that
# emits canned RPC responses based on env vars set per scenario. Pure bash;
# no test framework. Run with:
#
#   bash tests/test-borrow-contract.sh
#
# Exit code 0 = all scenarios behaved as expected.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BORROW_SH="$REPO_ROOT/aave-borrow.sh"
MOCKS_DIR="$SCRIPT_DIR/mocks"

if [ ! -x "$MOCKS_DIR/cast" ]; then
  echo "FATAL: mock cast not executable at $MOCKS_DIR/cast" >&2
  exit 2
fi

# Isolated working dir for the synthetic SKILL_DIR/config.json
WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t agent-credit-test)
trap 'rm -rf "$WORK_DIR"' EXIT

CONFIG_PATH="$WORK_DIR/config.json"
cat > "$CONFIG_PATH" <<'JSON'
{
  "chain": "test",
  "rpcUrl": "http://127.0.0.1:0",
  "agentPrivateKey": "0x0000000000000000000000000000000000000000000000000000000000000001",
  "delegatorAddress": "0x000000000000000000000000000000000000DEAD",
  "poolAddress": "0x0000000000000000000000000000000000000P00",
  "dataProviderAddress": "0x000000000000000000000000000000000000DA7A",
  "assets": {
    "USDC": {
      "address": "0x0000000000000000000000000000000000000U5D",
      "decimals": 6
    },
    "WETH": {
      "address": "0x0000000000000000000000000000000000000E70",
      "decimals": 18
    }
  },
  "safety": {
    "minHealthFactor": "1.5",
    "maxBorrowPerTx": "1000",
    "maxBorrowPerTxUnit": "USDC"
  }
}
JSON

PASS=0
FAIL=0
FAILURES=()

# Run aave-borrow.sh with a clean per-scenario env. Returns the script's exit
# code; full combined output is written to $WORK_DIR/last.out.
run_borrow() {
  local symbol="$1" amount="$2"
  (
    export PATH="$MOCKS_DIR:$PATH"
    export SKILL_DIR="$WORK_DIR"
    export CONFIG="$CONFIG_PATH"  # consumed by the mock for addr→symbol lookup
    bash "$BORROW_SH" "$symbol" "$amount"
  ) >"$WORK_DIR/last.out" 2>&1
}

# Assert: command exits non-zero AND stdout/stderr contains $tag.
expect_fail_with_tag() {
  local name="$1" tag="$2" rc="$3"
  if [ "$rc" -eq 0 ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected non-zero exit, got 0")
    echo "  FAIL $name: expected non-zero exit, got 0"
    echo "  --- output ---"
    sed 's/^/    /' "$WORK_DIR/last.out"
    return
  fi
  if ! grep -q -- "$tag" "$WORK_DIR/last.out"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: missing tag '$tag' in output")
    echo "  FAIL $name: missing tag '$tag' in output"
    echo "  --- output ---"
    sed 's/^/    /' "$WORK_DIR/last.out"
    return
  fi
  PASS=$((PASS+1))
  echo "  PASS $name (exit=$rc, matched '$tag')"
}

expect_success_reaching_execute() {
  local name="$1" rc="$2"
  # Positive case: at minimum, all four safety checks must pass. The mock's
  # `cast send` returns a canned tx hash, so a clean run exits 0.
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected exit 0, got $rc")
    echo "  FAIL $name: expected exit 0, got $rc"
    echo "  --- output ---"
    sed 's/^/    /' "$WORK_DIR/last.out"
    return
  fi
  if ! grep -q "Executing Borrow" "$WORK_DIR/last.out"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: never reached 'Executing Borrow' stage")
    echo "  FAIL $name: never reached 'Executing Borrow' stage"
    echo "  --- output ---"
    sed 's/^/    /' "$WORK_DIR/last.out"
    return
  fi
  PASS=$((PASS+1))
  echo "  PASS $name (exit=0, reached execute stage)"
}

# Reset all MOCK_* vars between scenarios so leakage from one to the next
# can't accidentally green-light a buggy script.
reset_mocks() {
  unset MOCK_AGENT_ADDR MOCK_ADDRESSES_PROVIDER MOCK_ORACLE \
        MOCK_PRICE_USDC MOCK_PRICE_WETH \
        MOCK_VAR_DEBT_USDC MOCK_VAR_DEBT_WETH \
        MOCK_ATOKEN_USDC MOCK_ATOKEN_WETH \
        MOCK_STABLE_DEBT_USDC MOCK_STABLE_DEBT_WETH \
        MOCK_ALLOWANCE_RAW \
        MOCK_TOTAL_COLLATERAL_BASE MOCK_TOTAL_DEBT_BASE \
        MOCK_AVAILABLE_BORROWS_BASE MOCK_LIQ_THRESHOLD_BPS MOCK_LTV_BPS \
        MOCK_HEALTH_FACTOR_RAW \
        MOCK_AGENT_BALANCE_WEI MOCK_GAS_PRICE_WEI \
        MOCK_TOKEN_BALANCEOF MOCK_TX_JSON || true
}

echo "=== aave-borrow.sh contract tests ==="
echo

# ---- Scenario 1: cap-bypass -------------------------------------------------
# Cap is 1000 USDC ≈ \$1000. Request: borrow 1 WETH at \$3000 → \$3000 borrow
# value. Pre-fix this passed silently (asset != cap unit). Post-fix it must
# trip Check 1 with AMOUNT_EXCEEDS_CAP.
echo "[scenario 1] cap-bypass: borrow 1 WETH against 1000 USDC cap"
reset_mocks
export MOCK_PRICE_USDC="100000000"          # \$1.00 (8-dec base)
export MOCK_PRICE_WETH="300000000000"       # \$3000.00
# Healthy account so we'd otherwise reach Check 4. (Check 1 must fire first.)
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"   # \$10,000
export MOCK_TOTAL_DEBT_BASE="0"
export MOCK_AVAILABLE_BORROWS_BASE="800000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
export MOCK_HEALTH_FACTOR_RAW="115792089237316195423570985008687907853269984665640564039457584007913129639935"
export MOCK_ALLOWANCE_RAW="1000000000000000000000"  # plenty
export MOCK_AGENT_BALANCE_WEI="1000000000000000000"
export MOCK_GAS_PRICE_WEI="1000000000"
run_borrow WETH 1
expect_fail_with_tag "cap-bypass (WETH 1 vs 1000 USDC cap)" "AMOUNT_EXCEEDS_CAP" $?

# ---- Scenario 2: HF-projection ---------------------------------------------
# \$10K collateral / 80% liq threshold / \$5K existing debt → current HF=1.6
# (passes minHealthFactor=1.5). Borrow 400 USDC → projected debt \$5400,
# adjusted collateral \$8000, projected HF = 8000/5400 ≈ 1.481 < 1.5.
# Must trip Check 3 with PROJECTED_HF_BELOW_MIN.
echo
echo "[scenario 2] HF-projection: borrow 400 USDC drops HF 1.6 -> 1.48"
reset_mocks
export MOCK_PRICE_USDC="100000000"
export MOCK_PRICE_WETH="300000000000"
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"   # \$10,000
export MOCK_TOTAL_DEBT_BASE="500000000000"          # \$5,000
export MOCK_AVAILABLE_BORROWS_BASE="300000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
# HF ≈ (10000*0.8)/5000 = 1.6 → 1.6 * 1e18
export MOCK_HEALTH_FACTOR_RAW="1600000000000000000"
export MOCK_ALLOWANCE_RAW="1000000000000"           # 1M USDC raw — generous
export MOCK_AGENT_BALANCE_WEI="1000000000000000000"
export MOCK_GAS_PRICE_WEI="1000000000"
run_borrow USDC 400
expect_fail_with_tag "hf-projection (400 USDC, HF 1.6 -> 1.48)" "PROJECTED_HF_BELOW_MIN" $?

# ---- Scenario 3: positive control ------------------------------------------
# Same \$10K collateral / 80% LT / \$5K debt, but borrow only 100 USDC →
# projected debt \$5100, HF = 8000/5100 ≈ 1.568 > 1.5. Cap: \$100 ≤ \$1000.
# Must clear all four checks and reach the execute stage.
echo
echo "[scenario 3] positive control: borrow 100 USDC, all checks should pass"
reset_mocks
export MOCK_PRICE_USDC="100000000"
export MOCK_PRICE_WETH="300000000000"
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"
export MOCK_TOTAL_DEBT_BASE="500000000000"
export MOCK_AVAILABLE_BORROWS_BASE="300000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
export MOCK_HEALTH_FACTOR_RAW="1600000000000000000"
export MOCK_ALLOWANCE_RAW="1000000000000"
export MOCK_AGENT_BALANCE_WEI="1000000000000000000"
export MOCK_GAS_PRICE_WEI="1000000000"
export MOCK_TX_JSON='{"transactionHash":"0xfeedface"}'
export MOCK_TOKEN_BALANCEOF="100000000"
run_borrow USDC 100
expect_success_reaching_execute "positive (100 USDC within cap & HF safe)" $?

echo
echo "=== summary ==="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
