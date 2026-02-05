# Aave V3 Contract Addresses

> All addresses below are **Aave V3** deployments. The skill also works with **Aave V2** (same function signatures for credit delegation) — just swap in the V2 LendingPool and ProtocolDataProvider addresses.

## Mainnet Deployments

### Base
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool (L2Pool)           | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`  |
| PoolAddressesProvider   | `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D`  |
| PoolDataProvider        | `0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac`  |
| WETHGateway             | `0x8be473dCfA93132559B118a2E512Fce0e459Bf8C`  |

**Common Assets on Base:**
| Token | Address                                      | Decimals |
|-------|----------------------------------------------|----------|
| USDC  | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6        |
| USDbC | `0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA` | 6        |
| WETH  | `0x4200000000000000000000000000000000000006`   | 18       |
| cbETH | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` | 18       |

### Ethereum Mainnet
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool                    | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`  |
| PoolAddressesProvider   | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e`  |
| PoolDataProvider        | `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3`  |

### Polygon
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool                    | `0x794a61358D6845594F94dc1DB02A252b5b4814aD`  |
| PoolAddressesProvider   | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb`  |
| PoolDataProvider        | `0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654`  |

### Arbitrum
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool                    | `0x794a61358D6845594F94dc1DB02A252b5b4814aD`  |
| PoolAddressesProvider   | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb`  |
| PoolDataProvider        | `0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654`  |

## Testnet Deployments

### Base Sepolia
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool                    | `0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b`  |
| PoolAddressesProvider   | `0xd449FeD49d9C443688d6816fE6872F21402e41de`  |

### Ethereum Sepolia
| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| Pool                    | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951`  |
| Faucet                  | Available at app.aave.com (testnet mode)      |

## How to Resolve DebtToken Addresses

DebtToken addresses are per-asset and per-chain. Look them up dynamically:

```bash
# Returns (aTokenAddress, stableDebtTokenAddress, variableDebtTokenAddress)
cast call $DATA_PROVIDER \
  "getReserveTokensAddresses(address)(address,address,address)" \
  $ASSET_ADDRESS \
  --rpc-url $RPC_URL
```

The **3rd return value** is the VariableDebtToken — that's the one the delegator calls `approveDelegation()` on.

## Delegator Setup

The delegator sets up collateral and delegation from **their own wallet** — via [app.aave.com](https://app.aave.com) and a block explorer. See [README.md](README.md) for the full step-by-step guide.

The delegator's private key should **never** be in this repo or config.

### Verify delegation (read-only, no key needed)
```bash
# Look up the VariableDebtToken for an asset
cast call $DATA_PROVIDER \
  "getReserveTokensAddresses(address)(address,address,address)" \
  $ASSET_ADDRESS --rpc-url $RPC

# Check allowance
cast call $VAR_DEBT "borrowAllowance(address,address)(uint256)" \
  $DELEGATOR_ADDRESS $AGENT_ADDRESS --rpc-url $RPC
```

## Official Resources

- **Aave Address Book (npm/Solidity)**: https://github.com/bgd-labs/aave-address-book
- **Deployed Contracts Docs**: https://docs.aave.com/developers/deployed-contracts
- **Interactive Dashboard**: https://aave.com/docs/resources/addresses
