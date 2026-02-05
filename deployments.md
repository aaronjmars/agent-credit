# Aave Deployments Reference

All addresses verified on-chain. The credit delegation functions (`approveDelegation`, `borrowAllowance`, `borrow`, `repay`) use identical signatures on both V2 and V3.

> **To look up any debt token dynamically:**
> ```bash
> # Returns (aToken, stableDebtToken, variableDebtToken)
> cast call $DATA_PROVIDER \
>   "getReserveTokensAddresses(address)(address,address,address)" \
>   $ASSET_ADDRESS --rpc-url $RPC_URL
> ```
> The **3rd return value** is the VariableDebtToken — that's what the delegator calls `approveDelegation()` on.

---

## Aave V3

### Base

| Contract           | Address                                      |
|--------------------|----------------------------------------------|
| Pool               | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| PoolAddressesProvider | `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D` |
| PoolDataProvider   | `0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac` |

| Token | Underlying | Decimals | aToken | VariableDebtToken |
|-------|-----------|----------|--------|-------------------|
| USDC  | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` | `0x59dca05b6c26dbd64b5381374aAaC5CD05644C28` |
| WETH  | `0x4200000000000000000000000000000000000006` | 18 | `0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7` | `0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E` |
| cbETH | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` | 18 | `0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad` | `0x1DabC36f19909425f654777249815c073E8Fd79F` |
| USDbC | `0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA` | 6 | `0x0a1d576f3eFeF75b330424287a95A366e8281D54` | `0x7376b2F323dC56fCd4C191B34163ac8a84702DAB` |

### Ethereum Mainnet

| Contract           | Address                                      |
|--------------------|----------------------------------------------|
| Pool               | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| PoolAddressesProvider | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` |
| PoolDataProvider   | `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3` |

| Token | Underlying | Decimals | aToken | VariableDebtToken |
|-------|-----------|----------|--------|-------------------|
| USDC  | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c` | `0x72E95b8931767C79bA4EeE721354d6E99a61D004` |
| USDT  | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | `0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a` | `0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8` |
| WETH  | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 | `0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8` | `0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE` |
| DAI   | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | 18 | `0x018008bfb33d285247A21d44E50697654f754e63` | `0xcF8d0c70c850859266f5C338b38F9D663181C314` |
| WBTC  | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | 8 | `0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8` | `0x40aAbEf1aa8f0eEc637E0E7d92fbfFB2F26A8b7B` |

### Polygon

| Contract           | Address                                      |
|--------------------|----------------------------------------------|
| Pool               | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| PoolAddressesProvider | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` |
| PoolDataProvider   | `0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654` |

| Token  | Underlying | Decimals | aToken | VariableDebtToken |
|--------|-----------|----------|--------|-------------------|
| USDC   | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | 6 | `0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD` | `0xE701126012EC0290822eEA17B794454d1AF8b030` |
| USDCe  | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | 6 | `0x625E7708f30cA75bfd92586e17077590C60eb4cD` | `0xFCCf3cAbbe80101232d343252614b6A3eE81C989` |
| USDT   | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | 6 | `0x6ab707Aca953eDAeFBc4fD23bA73294241490620` | `0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7` |
| WETH   | `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` | 18 | `0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8` | `0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351` |
| WMATIC | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` | 18 | `0x6d80113e533a2C0fe82EaBD35f1875DcEA89Ea97` | `0x4a1c3aD6Ed28a636ee1751C69071f6be75DEb8B8` |
| WBTC   | `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6` | 8 | `0x078f358208685046a11C85e8ad32895DED33A249` | `0x92b42c66840C7AD907b4BF74879FF3eF7c529473` |

### Arbitrum

| Contract           | Address                                      |
|--------------------|----------------------------------------------|
| Pool               | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| PoolAddressesProvider | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` |
| PoolDataProvider   | `0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654` |

| Token | Underlying | Decimals | aToken | VariableDebtToken |
|-------|-----------|----------|--------|-------------------|
| USDC  | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 | `0x724dc807b04555b71ed48a6896b6F41593b8C637` | `0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6` |
| USDCe | `0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8` | 6 | `0x625E7708f30cA75bfd92586e17077590C60eb4cD` | `0xFCCf3cAbbe80101232d343252614b6A3eE81C989` |
| USDT  | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 6 | `0x6ab707Aca953eDAeFBc4fD23bA73294241490620` | `0xfb00AC187a8Eb5AFAE4eACE434F493Eb62672df7` |
| WETH  | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | 18 | `0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8` | `0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351` |
| WBTC  | `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | 8 | `0x078f358208685046a11C85e8ad32895DED33A249` | `0x92b42c66840C7AD907b4BF74879FF3eF7c529473` |
| DAI   | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` | 18 | `0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE` | `0x8619d80FB0141ba7F184CbF22fd724116D9f7ffC` |
| ARB   | `0x912CE59144191C1204E64559FE8253a0e49E6548` | 18 | `0x6533afac2E7BCCB20dca161449A13A32D391fb00` | `0x44705f578135cC5d703b4c9c122528C73Eb87145` |

### Testnets

| Chain        | Pool                                           | Notes |
|--------------|------------------------------------------------|-------|
| Base Sepolia | `0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b` | PoolAddressesProvider: `0xd449FeD49d9C443688d6816fE6872F21402e41de` |
| Eth Sepolia  | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` | Faucet at app.aave.com (testnet mode) |

---

## Aave V2

> V2 was never deployed to Arbitrum or Base. V2 naming: LendingPool (not Pool), ProtocolDataProvider (not PoolDataProvider).
> V2's `getUserAccountData` returns values denominated in ETH (18 decimals), not USD (8 decimals) like V3. The health factor check still works identically.

### Ethereum Mainnet

| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| LendingPool             | `0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9` |
| LendingPoolAddressesProvider | `0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5` |
| ProtocolDataProvider    | `0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d` |

| Token | Underlying | Decimals | aToken | VariableDebtToken |
|-------|-----------|----------|--------|-------------------|
| USDC  | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | `0xBcca60bB61934080951369a648Fb03DF4F96263C` | `0x619beb58998eD2278e08620f97007e1116D5D25b` |
| USDT  | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | `0x3Ed3B47Dd13EC9a98b44e6204A523E766B225811` | `0x531842cEbbdD378f8ee36D171d6cC9C4fcf475Ec` |
| WETH  | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 18 | `0x030bA81f1c18d280636F32af80b9AAd02Cf0854e` | `0xF63B34710b3Af2B3f2c3645E98d5b14c83f4E94e` |
| DAI   | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | 18 | `0x028171bCA77440897B824Ca71D1c56caC55b68A3` | `0x6C3c78838c761c6Ac7bE9F59fe808ea2A6E4379d` |
| WBTC  | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | 8 | `0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656` | `0x9c39809Dec7F95F5e0713634a4D0701329B3b4d2` |

### Polygon

| Contract                | Address                                      |
|-------------------------|----------------------------------------------|
| LendingPool             | `0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf` |
| LendingPoolAddressesProvider | `0xd05e3E715d945B59290df0ae8eF85c1BdB684744` |
| ProtocolDataProvider    | `0x7551b5D2763519d4e37e8B81929D336De671d46d` |

| Token  | Underlying | Decimals | aToken | VariableDebtToken |
|--------|-----------|----------|--------|-------------------|
| USDCe  | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | 6 | `0x1a13F4Ca1d028320A707D99520AbFefca3998b7F` | `0x248960A9d75EdFa3de94F7193eae3161Eb349a12` |
| USDT   | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | 6 | `0x60D55F02A771d515e077c9C2403a1ef324885CeC` | `0x8038857FD47108A07d1f6Bf652ef1cBeC279A2f3` |
| WETH   | `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` | 18 | `0x28424507fefb6f7f8E9D3860F56504E4e5f5f390` | `0xeDe17e9d79fc6f9fF9250D9EEfbdB88Cc18038b5` |
| DAI    | `0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063` | 18 | `0x27F8D03b3a2196956ED754baDc28D73be8830A6e` | `0x75c4d1Fb84429023170086f06E682DcbBF537b7d` |
| WBTC   | `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6` | 8 | `0x5c2ed810328349100A66B82b78a1791B101C9D61` | `0xF664F50631A6f0D72ecdaa0e49b0c019Fa72a8dC` |
| WMATIC | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` | 18 | `0x8dF3aad3a84da6b69A4DA8aeC3eA40d9091B2Ac4` | `0x59e8E9100cbfCBCBAdf86b9279fa61526bBB8765` |

---

## V2 vs V3 Contract Naming

| V2                             | V3                    |
|--------------------------------|-----------------------|
| LendingPool                    | Pool                  |
| LendingPoolAddressesProvider   | PoolAddressesProvider |
| ProtocolDataProvider           | PoolDataProvider      |

The function signatures for credit delegation are identical across both versions.

---

## Sources

- [Aave V3 Deployed Contracts](https://docs.aave.com/developers/deployed-contracts)
- [Aave V2 Deployed Contracts](https://docs.aave.com/developers/v/2.0/deployed-contracts)
- [bgd-labs/aave-address-book](https://github.com/bgd-labs/aave-address-book)
- Debt tokens resolved on-chain via `getReserveTokensAddresses()` on each chain's DataProvider
