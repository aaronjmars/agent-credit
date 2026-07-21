#!/usr/bin/env bash
# tests/test-repay-contract.sh
#
# Contract-enforcement fixtures for aave-repay.sh. The invariants under test:
#
#   1. A repay is not idempotent — it pulls the agent's tokens each time. A
#      send whose receipt cannot be parsed must NEVER be retried.
#   2. A mined-but-reverted repay must not be reported as success.
#   3. A failed send must exit non-zero with the underlying error.
#   4. The repay argv must be exact: onBehalfOf the delegator, rate mode 2,
#      and type(uint256).max on a max repay so Aave settles the exact debt.
#   5. Insufficient agent balance must abort before any transaction.
#
# Same approach as test-borrow-contract.sh: $PATH is prepended with
# tests/mocks/ which contains a stub `cast` driven by MOCK_* env vars.
#
#   bash tests/test-repay-contract.sh
#
# Exit code 0 = all scenarios behaved as expected.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPAY_SH="$REPO_ROOT/aave-repay.sh"
MOCKS_DIR="$SCRIPT_DIR/mocks"

if [ ! -x "$MOCKS_DIR/cast" ]; then
  echo "FATAL: mock cast not executable at $MOCKS_DIR/cast" >&2
  exit 2
fi

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
    }
  }
}
JSON

PASS=0
FAIL=0
FAILURES=()

run_repay() {
  local symbol="$1" amount="$2"
  (
    unset AAVE_RPC_URL AAVE_AGENT_PRIVATE_KEY AAVE_DELEGATOR_ADDRESS \
          AAVE_POOL_ADDRESS AAVE_MIN_HEALTH_FACTOR AAVE_BASE_CURRENCY_DECIMALS
    export PATH="$MOCKS_DIR:$PATH"
    export SKILL_DIR="$WORK_DIR"
    export CONFIG="$CONFIG_PATH"
    export MOCK_SEND_LOG="$WORK_DIR/send.log"
    bash "$REPAY_SH" "$symbol" "$amount"
  ) >"$WORK_DIR/last.out" 2>&1
}

fail_with() {
  local name="$1" why="$2"
  FAIL=$((FAIL+1))
  FAILURES+=("$name: $why")
  echo "  FAIL $name: $why"
  echo "  --- output ---"
  sed 's/^/    /' "$WORK_DIR/last.out"
}

expect_fail_with_tag() {
  local name="$1" tag="$2" rc="$3"
  if [ "$rc" -eq 0 ]; then fail_with "$name" "expected non-zero exit, got 0"; return; fi
  if ! grep -q -- "$tag" "$WORK_DIR/last.out"; then
    fail_with "$name" "missing tag '$tag'"; return
  fi
  PASS=$((PASS+1)); echo "  PASS $name (exit=$rc, matched '$tag')"
}

expect_ok() {
  local name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then fail_with "$name" "expected exit 0, got $rc"; return; fi
  PASS=$((PASS+1)); echo "  PASS $name (exit=0)"
}

# Assert the script did NOT claim success. Guards the false-success path where
# a reverted receipt was reported as "Repayment successful!".
expect_not_success_message() {
  local name="$1"
  if grep -q "Repayment successful" "$WORK_DIR/last.out"; then
    fail_with "$name" "reported success for a failed repay"; return
  fi
  PASS=$((PASS+1)); echo "  PASS $name (did not claim success)"
}

# Assert exactly N `cast send` calls were made.
expect_send_count() {
  local name="$1" want="$2"
  local log="$WORK_DIR/send.log" got
  got=$([ -f "$log" ] && wc -l <"$log" | tr -d ' ' || echo 0)
  if [ "$got" != "$want" ]; then
    fail_with "$name" "expected $want cast send call(s), saw $got"
    [ -f "$log" ] && sed 's/^/    send: /' "$log"
    return
  fi
  PASS=$((PASS+1)); echo "  PASS $name ($got send call(s))"
}

expect_send_matches() {
  local name="$1" pattern="$2"
  local log="$WORK_DIR/send.log"
  if [ ! -f "$log" ] || ! grep -q -- "$pattern" "$log"; then
    fail_with "$name" "no cast send matching: $pattern"
    [ -f "$log" ] && sed 's/^/    send: /' "$log"
    return
  fi
  PASS=$((PASS+1)); echo "  PASS $name (argv matched)"
}

reset_mocks() {
  unset MOCK_AGENT_ADDR MOCK_ADDRESSES_PROVIDER MOCK_ORACLE \
        MOCK_VAR_DEBT_USDC MOCK_ATOKEN_USDC MOCK_STABLE_DEBT_USDC \
        MOCK_ALLOWANCE_RAW MOCK_ERC20_ALLOWANCE \
        MOCK_TOKEN_BALANCEOF MOCK_DEBT_BALANCEOF MOCK_TX_JSON || true
  rm -f "$WORK_DIR/send.log"
}

# Delegator owes 100 USDC; agent holds 500 USDC; pool already approved.
standard_position() {
  export MOCK_DEBT_BALANCEOF="100000000"     # 100 USDC debt
  export MOCK_TOKEN_BALANCEOF="500000000"    # 500 USDC held by agent
  export MOCK_ERC20_ALLOWANCE="500000000"    # approval already in place
}

echo "=== aave-repay.sh contract tests ==="
echo

# ---- Scenario 1: unparseable receipt must not re-send -----------------------
# The failure that matters most. cast exits 0 (the repay landed on-chain) but
# emits something jq cannot read. Re-sending would pull the agent's tokens a
# second time for a debt that is already settled.
echo "[scenario 1] unparseable receipt: must NOT broadcast a second repay"
reset_mocks; standard_position
export MOCK_TX_JSON='Warning: legacy gas estimation'   # not JSON
run_repay USDC 100
expect_send_count "unparseable receipt (exactly one send)" 1
expect_not_success_message "unparseable receipt (no false success)"

# ---- Scenario 2: reverted receipt must not report success -------------------
# A reverted receipt still contains a blockHash, and Foundry prints blockHash
# before transactionHash — so scraping the first 64-hex string yielded a hash
# and the script declared victory on a repay that never happened.
echo
echo "[scenario 2] reverted receipt must be reported as a failure"
reset_mocks; standard_position
export MOCK_TX_JSON='{"blockHash":"0x1111111111111111111111111111111111111111111111111111111111111111","transactionHash":"0x2222222222222222222222222222222222222222222222222222222222222222","status":"0x0"}'
run_repay USDC 100
expect_fail_with_tag "reverted repay" "REPAY_REVERTED" $?
expect_not_success_message "reverted repay (no false success)"

# ---- Scenario 3: happy path, exact argv -------------------------------------
echo
echo "[scenario 3] successful repay of 100 USDC"
reset_mocks; standard_position
export MOCK_TX_JSON='{"transactionHash":"0xfeedface","status":"0x1"}'
run_repay USDC 100
expect_ok "successful repay" $?
expect_send_count "successful repay (one send, approval already in place)" 1
# 100 USDC at 6 decimals = 100000000. onBehalfOf MUST be the delegator.
expect_send_matches "successful repay (argv)" \
  "0x0000000000000000000000000000000000000F00 repay(address,uint256,uint256,address) 0x00000000000000000000000000000000000005DC 100000000 2 0x000000000000000000000000000000000000DEAD"

# ---- Scenario 4: max repay passes uint256.max -------------------------------
# Aave settles the exact debt at execution time only if given uint256.max;
# passing a quoted amount leaves dust behind as interest accrues.
echo
echo "[scenario 4] max repay must pass type(uint256).max, not a quoted amount"
reset_mocks; standard_position
export MOCK_TX_JSON='{"transactionHash":"0xfeedface","status":"0x1"}'
run_repay USDC max
expect_ok "max repay" $?
expect_send_matches "max repay (uint256.max in argv)" \
  "repay(address,uint256,uint256,address) 0x00000000000000000000000000000000000005DC 115792089237316195423570985008687907853269984665640564039457584007913129639935 2 0x000000000000000000000000000000000000DEAD"

# ---- Scenario 5: insufficient balance aborts before any send ----------------
echo
echo "[scenario 5] agent without enough tokens must abort before sending"
reset_mocks
export MOCK_DEBT_BALANCEOF="100000000"    # owes 100
export MOCK_TOKEN_BALANCEOF="10000000"    # holds only 10
export MOCK_ERC20_ALLOWANCE="500000000"
export MOCK_TX_JSON='{"transactionHash":"0xfeedface","status":"0x1"}'
run_repay USDC 100
if [ $? -eq 0 ]; then
  fail_with "insufficient balance" "expected non-zero exit"
else
  PASS=$((PASS+1)); echo "  PASS insufficient balance (exit non-zero)"
fi
expect_send_count "insufficient balance (no send)" 0

echo
echo "=== summary ==="
echo "  passed: $PASS"
echo "  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
