# Delegator Setup Guide

This guide walks you through setting up credit delegation so an AI agent can borrow from Aave on your behalf. You (the delegator) supply collateral and control exactly what the agent can borrow. The agent never touches your private key.

## How It Works

Your borrowing power comes from your **total collateral position** — it's holistic. If you deposit $10k of ETH at 80% LTV, you have $8k of borrowing capacity across any asset Aave offers.

Delegation approval is **isolated per debt token**. You choose which assets the agent can borrow and set a ceiling for each, independently. The agent cannot borrow anything you haven't explicitly approved.

```
You deposit collateral          You approve per-asset delegation
┌──────────────────────┐        ┌────────────────────────────────┐
│  ETH   → $5,000      │        │  USDC debt token → agent: 500  │
│  USDC  → $3,000      │  LTV   │  WETH debt token → agent: 0.5  │
│  cbETH → $2,000      │ ────▶  │  DAI  debt token → agent: 0    │
│                       │  80%   │                                │
│  Total: $10k          │ = $8k  │  Agent can borrow USDC + WETH  │
│  Capacity: $8k        │        │  Agent CANNOT borrow DAI       │
└──────────────────────┘        └────────────────────────────────┘
```

Works on **Aave V2** and **Aave V3** — the credit delegation functions are identical across both versions. See [deployments.md](deployments.md) for all contract addresses.

---

## Prerequisites

Install [Foundry](https://book.getfoundry.sh/) for the `cast` CLI:

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

Set your variables (adjust for your chain — this example uses Base):

```bash
# Your wallet
export YOUR_PK="0xYOUR_PRIVATE_KEY"
export YOUR_ADDRESS="0xYOUR_WALLET_ADDRESS"

# Agent wallet (you'll get this from the agent config)
export AGENT_ADDRESS="0xAGENT_WALLET_ADDRESS"

# Base V3 addresses (see deployments.md for other chains)
export RPC="https://mainnet.base.org"
export POOL="0xA238Dd80C259a72e81d7e4664a9801593F98d1c5"
export DATA_PROVIDER="0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac"
```

---

## Step 1: Supply Collateral

You need collateral in Aave before anything can be borrowed against it. If you already have a position on Aave (via the web UI at [app.aave.com](https://app.aave.com)), skip to Step 2.

### Supply an ERC-20 token (e.g. WETH on Base)

```bash
TOKEN="0x4200000000000000000000000000000000000006"  # WETH on Base
AMOUNT="10000000000000000"                           # 0.01 WETH in raw units

# Approve the Pool to pull your tokens
cast send $TOKEN \
  "approve(address,uint256)" $POOL $AMOUNT \
  --private-key $YOUR_PK --rpc-url $RPC

# Supply to Aave
cast send $POOL \
  "supply(address,uint256,address,uint16)" \
  $TOKEN $AMOUNT $YOUR_ADDRESS 0 \
  --private-key $YOUR_PK --rpc-url $RPC
```

### Verify your position

```bash
cast call $POOL \
  "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" \
  $YOUR_ADDRESS --rpc-url $RPC
```

Returns 6 values:
1. Total collateral (V3: USD with 8 decimals / V2: ETH with 18 decimals)
2. Total debt
3. Available borrows
4. Current liquidation threshold
5. LTV
6. Health factor (18 decimals — divide by 1e18)

---

## Step 2: Approve Delegation

This is the key step. You call `approveDelegation()` on the **VariableDebtToken** of each asset you want the agent to borrow.

### Find the VariableDebtToken address

```bash
# Example: find the USDC debt token on Base
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

cast call $DATA_PROVIDER \
  "getReserveTokensAddresses(address)(address,address,address)" \
  $USDC --rpc-url $RPC
```

Returns 3 addresses:
1. aToken (receipt token for suppliers)
2. StableDebtToken (not used for delegation)
3. **VariableDebtToken** ← this is the one you need

Or just look it up in [deployments.md](deployments.md).

### Approve the agent

```bash
VAR_DEBT_TOKEN="0x59dca05b6c26dbd64b5381374aAaC5CD05644C28"  # USDC VariableDebtToken on Base

# Allow the agent to borrow up to 500 USDC (500 * 10^6 = 500000000)
cast send $VAR_DEBT_TOKEN \
  "approveDelegation(address,uint256)" \
  $AGENT_ADDRESS 500000000 \
  --private-key $YOUR_PK --rpc-url $RPC
```

### Approve multiple assets

Each asset has its own debt token. Approve them separately:

```bash
# USDC — up to 500
cast send "0x59dca05b6c26dbd64b5381374aAaC5CD05644C28" \
  "approveDelegation(address,uint256)" $AGENT_ADDRESS 500000000 \
  --private-key $YOUR_PK --rpc-url $RPC

# WETH — up to 0.1
cast send "0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E" \
  "approveDelegation(address,uint256)" $AGENT_ADDRESS 100000000000000000 \
  --private-key $YOUR_PK --rpc-url $RPC
```

The agent cannot borrow any asset you haven't approved.

---

## Step 3: Verify

### Check a specific delegation allowance

```bash
cast call $VAR_DEBT_TOKEN \
  "borrowAllowance(address,address)(uint256)" \
  $YOUR_ADDRESS $AGENT_ADDRESS --rpc-url $RPC
```

Returns the remaining allowance in raw units. Each borrow the agent makes reduces this number.

### Run the full status check

If the agent skill is configured:

```bash
./aave-status.sh
```

This shows delegation allowances, health factor, and outstanding debt for all configured assets.

---

## Step 4: Fund the Agent Wallet for Gas

The agent wallet needs a small amount of native token to pay for transaction gas. It doesn't need much — on Base, a borrow transaction costs ~$0.01.

Send a tiny amount of ETH to the agent address:

```bash
cast send $AGENT_ADDRESS \
  --value 0.001ether \
  --private-key $YOUR_PK --rpc-url $RPC
```

---

## Managing Delegation

### Increase an allowance

Call `approveDelegation` again with the new total. It **replaces** the previous value (not additive):

```bash
# Increase USDC delegation to 1000
cast send $VAR_DEBT_TOKEN \
  "approveDelegation(address,uint256)" \
  $AGENT_ADDRESS 1000000000 \
  --private-key $YOUR_PK --rpc-url $RPC
```

### Revoke delegation for one asset

Set the allowance to 0:

```bash
cast send $VAR_DEBT_TOKEN \
  "approveDelegation(address,uint256)" \
  $AGENT_ADDRESS 0 \
  --private-key $YOUR_PK --rpc-url $RPC
```

### Revoke all delegation

Call `approveDelegation(..., 0)` on every VariableDebtToken you previously approved.

### Check outstanding debt

If the agent has borrowed, debt accrues on your position. Check it:

```bash
# Check your variable debt balance for a specific asset
cast call $VAR_DEBT_TOKEN \
  "balanceOf(address)(uint256)" \
  $YOUR_ADDRESS --rpc-url $RPC
```

### Repay debt yourself

You can repay debt directly without the agent:

```bash
# Approve Pool to spend your USDC
cast send $USDC "approve(address,uint256)" $POOL $AMOUNT \
  --private-key $YOUR_PK --rpc-url $RPC

# Repay (use max uint to repay entire debt)
cast send $POOL \
  "repay(address,uint256,uint256,address)" \
  $USDC 115792089237316195423570985008687907853269984665640564039457584007913129639935 2 $YOUR_ADDRESS \
  --private-key $YOUR_PK --rpc-url $RPC
```

---

## Using the Aave Web UI Instead

All of the above can also be done through **[app.aave.com](https://app.aave.com)** — supply collateral and manage your position there. The only step that requires `cast` (or direct contract interaction) is `approveDelegation`, since the Aave UI doesn't expose credit delegation.

For delegation via Etherscan/Basescan instead of `cast`:

1. Go to the VariableDebtToken contract on the block explorer (find the address in [deployments.md](deployments.md))
2. Click **Write Contract** → **Connect Wallet**
3. Find `approveDelegation`
4. Enter the agent address and the amount in raw units
5. Submit the transaction

---

## Safety Recommendations

- **Start small.** Approve $50-100 initially. Increase after you've tested the flow.
- **Never approve `type(uint256).max`.** Always set a concrete ceiling per asset.
- **Monitor your health factor.** Set up alerts on [app.aave.com](https://app.aave.com) or [DeFi Saver](https://defisaver.com).
- **Revoke when idle.** If the agent doesn't need to borrow for a while, set delegation to 0.
- **Prefer stablecoins for borrowing.** Borrowing USDC against ETH collateral is simpler to reason about than volatile-on-volatile.
- **Test on a testnet first.** Use Base Sepolia or Ethereum Sepolia with faucet tokens before real funds.

See [safety.md](safety.md) for the full threat model and emergency procedures.

---

## Quick Reference

| Action | Command |
|--------|---------|
| Supply collateral | `cast send $POOL "supply(address,uint256,address,uint16)" $TOKEN $AMOUNT $YOU 0` |
| Approve delegation | `cast send $VAR_DEBT "approveDelegation(address,uint256)" $AGENT $AMOUNT` |
| Check allowance | `cast call $VAR_DEBT "borrowAllowance(address,address)(uint256)" $YOU $AGENT` |
| Revoke delegation | `cast send $VAR_DEBT "approveDelegation(address,uint256)" $AGENT 0` |
| Check health factor | `cast call $POOL "getUserAccountData(address)(...)" $YOU` |
| Check debt | `cast call $VAR_DEBT "balanceOf(address)(uint256)" $YOU` |
| Fund agent gas | `cast send $AGENT --value 0.001ether` |
