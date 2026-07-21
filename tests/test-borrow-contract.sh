#!/usr/bin/env bash
# tests/test-borrow-contract.sh
#
# Contract-enforcement fixtures for aave-borrow.sh. The invariants under test:
#
#   1. Cap-bypass: borrow WETH 1 against a `1000 USDC` cap must FAIL Check 1
#      (cross-asset cap binds via base-currency normalization).
#   2. HF-projection: a borrow that leaves *current* HF healthy but projected
#      HF below `minHealthFactor` must FAIL Check 3.
#   3. Positive control: a borrow within cap with projected HF safe must clear
#      all four checks and reach the borrow-execute branch.
#   4. Gas floor: a 0 gas-price must not disable Check 4; the 1e14 wei floor
#      applies regardless.
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
  "poolAddress": "0x0000000000000000000000000000000000000F00",
  "dataProviderAddress": "0x000000000000000000000000000000000000DA7A",
  "assets": {
    "USDC": {
      "address": "0x00000000000000000000000000000000000005DC",
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
    # Scrub ambient AAVE_* so a developer's shell cannot change what these
    # scenarios exercise. AAVE_MIN_HEALTH_FACTOR in particular overrides the
    # config value and would silently retune every health-factor assertion.
    unset AAVE_RPC_URL AAVE_AGENT_PRIVATE_KEY AAVE_DELEGATOR_ADDRESS \
          AAVE_POOL_ADDRESS AAVE_MIN_HEALTH_FACTOR AAVE_BASE_CURRENCY_DECIMALS
    export PATH="$MOCKS_DIR:$PATH"
    export SKILL_DIR="$WORK_DIR"
    export CONFIG="$CONFIG_PATH"  # consumed by the mock for addr→symbol lookup
    export MOCK_SEND_LOG="$WORK_DIR/send.log"
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

# Assert: exactly one `cast send` was issued, with exactly these positional
# args. Guards the delegation model itself — onBehalfOf must be the delegator,
# the rate mode must be variable (2), and the amount must be correctly scaled.
expect_send_args() {
  local name="$1" expected="$2"
  local log="$WORK_DIR/send.log"
  local actual sends
  sends=$([ -f "$log" ] && wc -l <"$log" || echo 0)
  if [ "$sends" -ne 1 ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected exactly 1 cast send, saw $sends")
    echo "  FAIL $name: expected exactly 1 cast send, saw $sends"
    [ -f "$log" ] && sed 's/^/    /' "$log"
    return
  fi
  actual=$(cat "$log")
  if [ "$actual" != "$expected" ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: cast send argv mismatch")
    echo "  FAIL $name: cast send argv mismatch"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    return
  fi
  PASS=$((PASS+1))
  echo "  PASS $name (borrow argv exact)"
}

# Assert: no transaction was broadcast. A rejected borrow that still sent a tx
# would be the worst possible outcome — the guard fires but the money moves.
expect_no_send() {
  local name="$1"
  local log="$WORK_DIR/send.log"
  if [ -s "$log" ]; then
    FAIL=$((FAIL+1))
    FAILURES+=("$name: expected no cast send, but one was issued")
    echo "  FAIL $name: expected no cast send, but one was issued"
    sed 's/^/    /' "$log"
    return
  fi
  PASS=$((PASS+1))
  echo "  PASS $name (no tx broadcast)"
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
        MOCK_TOKEN_BALANCEOF MOCK_TX_JSON MOCK_ANNOTATE || true
  rm -f "$WORK_DIR/send.log"
}

echo "=== aave-borrow.sh contract tests ==="
echo

# ---- Scenario 1: cap-bypass -------------------------------------------------
# Cap is 1000 USDC ≈ \$1000. Request: borrow 1 WETH at \$3000 → \$3000 borrow
# value. The cap binds across assets, so this must trip Check 1 with
# AMOUNT_EXCEEDS_CAP even though the borrowed asset is not the cap unit.
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
# 100 USDC at 6 decimals = 100000000. Rate mode 2 = variable, referral 0, and
# onBehalfOf MUST be the delegator — borrowing onBehalfOf the agent would move
# the debt to the wrong party and break the whole delegation model.
expect_send_args "positive (borrow argv)" \
  "0x0000000000000000000000000000000000000F00 borrow(address,uint256,uint256,uint16,address) 0x00000000000000000000000000000000000005DC 100000000 2 0 0x000000000000000000000000000000000000DEAD"

# ---- Scenario 4: gas-price-zero floor --------------------------------------
# A 0 gas-price (transient RPC issue / chain quirk) must not collapse
# MIN_GAS_WEI to 0 and green-light Check 4 for any non-zero balance. The
# script falls back to a 0.0001 ETH floor (1e14 wei), so an agent balance of
# 1e10 wei (0.00000001 ETH) must trip INSUFFICIENT_GAS.
echo
echo "[scenario 4] gas-price-zero: 1e10 wei balance must fail despite gas-price=0"
reset_mocks
export MOCK_PRICE_USDC="100000000"
export MOCK_PRICE_WETH="300000000000"
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"
export MOCK_TOTAL_DEBT_BASE="0"
export MOCK_AVAILABLE_BORROWS_BASE="800000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
export MOCK_HEALTH_FACTOR_RAW="115792089237316195423570985008687907853269984665640564039457584007913129639935"
export MOCK_ALLOWANCE_RAW="1000000000000"
export MOCK_AGENT_BALANCE_WEI="10000000000"   # 1e10 wei = 0.00000001 ETH
export MOCK_GAS_PRICE_WEI="0"                 # simulate RPC quirk / failure
run_borrow USDC 100
expect_fail_with_tag "gas-price-zero floor (0.00000001 ETH < 0.0001 ETH floor)" "INSUFFICIENT_GAS" $?

# ---- Scenario 5: zero oracle price ------------------------------------------
# getAssetPrice returns 0 (not a revert) for an address the oracle has no
# price source for — i.e. a typo'd or wrong-chain asset address. A zero price
# makes the borrow value 0, which passes the cap check AND leaves the HF
# projection unchanged, so a huge borrow clears both. Must refuse instead.
echo
echo "[scenario 5] zero-oracle-price: must refuse rather than price-blind borrow"
reset_mocks
export MOCK_PRICE_USDC="0"                  # oracle has no price source
export MOCK_PRICE_WETH="300000000000"
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"
export MOCK_TOTAL_DEBT_BASE="500000000000"
export MOCK_AVAILABLE_BORROWS_BASE="300000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
export MOCK_HEALTH_FACTOR_RAW="1600000000000000000"
export MOCK_ALLOWANCE_RAW="100000000000000000000"
export MOCK_AGENT_BALANCE_WEI="1000000000000000000"
export MOCK_GAS_PRICE_WEI="1000000000"
run_borrow USDC 1000000
expect_fail_with_tag "zero-oracle-price (1M USDC at price 0)" "ORACLE_PRICE_UNAVAILABLE" $?
expect_no_send "zero-oracle-price (no tx sent)"

# ---- Scenario 6: unusable minHealthFactor -----------------------------------
# MIN_HF is only consumed inside `if (( $(... | bc) ))`, where a bc parse error
# expands to `(( ))` = false and `set -e` does not apply. A non-numeric value
# therefore used to disable BOTH health-factor gates while still printing
# "Health factor OK". Must fail loudly at the boundary instead.
echo
echo "[scenario 6] non-numeric minHealthFactor must abort, not skip the HF gate"
reset_mocks
export MOCK_PRICE_USDC="100000000"
export MOCK_PRICE_WETH="300000000000"
export MOCK_TOTAL_COLLATERAL_BASE="1000000000000"
export MOCK_TOTAL_DEBT_BASE="900000000000"   # HF would be 0.89 — deeply unsafe
export MOCK_AVAILABLE_BORROWS_BASE="300000000000"
export MOCK_LIQ_THRESHOLD_BPS="8000"
export MOCK_HEALTH_FACTOR_RAW="890000000000000000"
export MOCK_ALLOWANCE_RAW="1000000000000"
export MOCK_AGENT_BALANCE_WEI="1000000000000000000"
export MOCK_GAS_PRICE_WEI="1000000000"
(
  export AAVE_MIN_HEALTH_FACTOR="1,5"        # locale comma — bc cannot parse
  export PATH="$MOCKS_DIR:$PATH"
  export SKILL_DIR="$WORK_DIR"
  export CONFIG="$CONFIG_PATH"
  export MOCK_SEND_LOG="$WORK_DIR/send.log"
  bash "$BORROW_SH" USDC 100
) >"$WORK_DIR/last.out" 2>&1
expect_fail_with_tag "non-numeric minHealthFactor" "INVALID_CONFIG" $?
expect_no_send "non-numeric minHealthFactor (no tx sent)"

# ---- Scenario 7: negative amount --------------------------------------------
# A negative amount passed every check: the cap comparison passes, and a
# negative debt delta *raises* the projected health factor.
echo
echo "[scenario 7] negative amount must be rejected before any check"
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
run_borrow USDC -100
expect_fail_with_tag "negative amount" "INVALID_AMOUNT" $?
expect_no_send "negative amount (no tx sent)"

# ---- Scenario 8: cast bracket annotations ----------------------------------
# Real cast prints large integers as "1600000000000000000 [1.6e18]". strip_cast
# exists solely to remove that, is applied at 20+ call sites, and was never
# exercised — the mock emitted bare decimals everywhere. Break strip_cast and
# every other scenario still passed. With MOCK_ANNOTATE=1 the same positive
# control must still clear all four checks and build the identical argv.
echo
echo "[scenario 8] annotated cast output must be stripped before any arithmetic"
reset_mocks
export MOCK_ANNOTATE=1
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
expect_success_reaching_execute "annotated output (all checks pass)" $?
expect_send_args "annotated output (argv identical to unannotated)" \
  "0x0000000000000000000000000000000000000F00 borrow(address,uint256,uint256,uint16,address) 0x00000000000000000000000000000000000005DC 100000000 2 0 0x000000000000000000000000000000000000DEAD"
unset MOCK_ANNOTATE

echo
echo "=== summary ==="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
