# FactoryHook — v1.0 / v1.1

Two standalone Foundry projects, one per version of `FactoryHook.sol`. Each carries the hook, the
interfaces it compiles against, the forge dependencies it is built with, the settings it is built
under, and its test suites, so `forge test` and `forge coverage` run on either version with nothing
else installed.

| Folder | Hook version |
|---|---|
| `v1.0/` | The hook deployed on Robinhood Chain (4663), at `0xb31780AAd49D3Cc7Dd6E03E9e462606F0A5A30Cc`. Live liquidity still runs on it. |
| `v1.1/` | v1.0 patched after audit: the L-04 fix, plus a change that pins each pool to the hook that registered it. |

Both ship because both matter: v1.1 is the version to read, v1.0 is the version pools are trading
against today. `v1.0` and `v1.1` are labels for these two hook versions here, not version numbers
used anywhere else.

### v1.0 is the deployed bytecode — verified

`./verify-v1.0-onchain.sh` builds `v1.0`, fetches the runtime code of
`0xb31780AAd49D3Cc7Dd6E03E9e462606F0A5A30Cc` over `https://rpc.mainnet.chain.robinhood.com`
(override with `ROBINHOOD_RPC_URL`) and compares the two with the hook's two immutables masked.
Result at block 47 850 899: **all 19 382 executable bytes identical**, on the runtime code and on
the CREATE2 initcode of the deployment (salt `0x…451a`, through the deterministic deployer proxy
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, with the constructor arguments it was deployed with).

The only bytes that differ are the 34-byte IPFS hash inside solc's trailing metadata CBOR. That
hash covers the metadata JSON, which includes the auto-detected remapping list of the build
environment: the same sources give three different hashes when built with the nested
`lib/uniswap-hooks/lib` present (one extra `halmos-cheatcodes/` remapping), without it, or with
`auto_detect_remappings = false`, and the deployer's environment was a fourth. No executable
difference can hide behind an identical code section, so the metadata hash is documented rather
than reproduced.

### What changed between the two

`CHANGES-v1.0-to-v1.1.diff` is the unified diff of the two `src/` trees. The functional changes are
in `src/hook/FactoryHook.sol` — `_checkpointSwap` clamps against a per-block `anchorTick` instead of
the previous swap's tick, which is the L-04 fix; `_afterInitialize` seeds that anchor; the three
`IExtensionHost` views arrive — and in `src/interfaces/IFactoryHook.sol` (`PoolState.anchorTick` /
`anchorTimestamp`, `IFactoryHook is IExtensionHost`). `IWETH.sol` gains `withdraw`. The rest of the
diff is NatSpec.

## Running

```bash
cd v1.0      # or v1.1
forge build
forge test
forge coverage                       # add --report lcov for an lcov.info
forge test --match-path 'test/PoC_H*' -vv   # the oracle PoCs, with their console output
```

Built and verified with `forge 1.7.1` (solc `0.8.26`, pinned in `foundry.toml`; forge downloads it
on first build). Both versions: **all tests pass**.

| | v1.0 | v1.1 |
|---|---|---|
| Test suites / tests | 36 / 167 | 40 / 183 |
| `FactoryHook.sol` line coverage | 99.68 % (307/308) | 100 % (320/320) |
| `FactoryHook.sol` branch coverage | 98.61 % (71/72) | 98.63 % (72/73) |
| `FactoryHook.sol` function coverage | 97.22 % | 100 % |

`forge build` prints `Warning: Failed to get git revision for dependency ...` because
`foundry.lock` pins the dependency revisions but the `lib/` copies carry no `.git` metadata. It is
informational; the revisions it names are the ones shipped (see *Dependencies*).

## What is in each project

```
v1.x/
├── foundry.toml, remappings.txt, foundry.lock   # the settings the hook is built under
├── src/hook/FactoryHook.sol                     # THE contract under test
├── src/interfaces/**, src/CooldownHolder.sol    # its import closure: interfaces, plus the one
│                                                #  concrete type they return
├── script/utils/HookAddressMiner.sol            # the CREATE2 salt miner the tests deploy the hook with
└── test/                                        # the hook's suites and the harness they run against
```

Nothing beyond the hook and that import closure is included.

### Dependencies (`lib/`)

The four libraries the build needs, at the revisions pinned in `foundry.lock`:

| Library | Revision | Remapped as |
|---|---|---|
| `forge-std` | `bb4ceea` (v1.8.1) | `forge-std/` |
| `openzeppelin-contracts` | `dbb6104` (v5.0.0-12) | `@openzeppelin/contracts/` |
| `uniswap-hooks` (OpenZeppelin) | `acbd604` (v1.2.0-rc.0-21) | `@openzeppelin/uniswap-hooks/` — only `src/base/BaseHook.sol` is used |
| `v4-periphery` (+ nested `v4-core`, `permit2`, `solmate`) | `3245c3c` | `@uniswap/v4-periphery/`, `@uniswap/v4-core/`, `permit2/`, `solmate/` |

To keep the archive small, directories the build never reads were removed from the copies:
`lib/uniswap-hooks/lib/` (its own nested copies of v4-core / v4-periphery / OpenZeppelin —
`remappings.txt` resolves everything to `lib/v4-periphery/lib/v4-core`), and every `audits/`,
`docs/`, `broadcast/`, `node_modules/` and `.git*` inside `lib/`. Source trees are intact.

## The test harness

The hook reads four contracts it does not own. Each is replaced here by a mock in
`test/helpers/ProtocolMocks.sol` implementing exactly the surface the hook touches, and nothing
more:

| Mock stands in for | Surface the hook uses |
|---|---|
| the coin factory | `owner()`, `treasury()`, `liquidityManager()` |
| a coin | ERC-20 + `isLPd()`, `lpdAt()`, `getFeeRecipient()` |
| the staking vault | ERC-20 shares + `asset()`, `hook()`, `deposit()`, `totalSupply()`, `notifyWethReward()` (the live accounting, unchanged), `pendingWeth()`, `wethRewardPerShare()` |
| the vault factory | `hook()`, `setHook()` (owner), `deployVault()` (hook-only) |

`test/helpers/HookTestBase.sol` is what every suite inherits. It boots the **real** in-process
Uniswap V4 stack (`PoolManager`, `PositionManager`, Permit2 runtime, `PoolSwapTest` router), deploys
`FactoryHook` at a mined address, registers pools with the hook and initializes them, and stands in
as every coin's fee recipient. `_deployCoin(...)` creates a coin. `_graduate(coin)` reproduces the
live graduation shape: 150 M coins below the seed tick and 4 ETH above it seed the pool, the 850 M
curve-sold coins land on `buyerOne`, and the coin is flagged LP'd. The helpers the test bodies call
(`_swapEthForCoin`, `_swapCoinForEth`, `_stakeIntoVault`, `_poolId`, `users`, `weth`, `swapRouter`,
...) keep the names and semantics they have against the live stack, so the bodies read the same.

### Suites

| File | Notes |
|---|---|
| `FactoryHook.t.sol` | integration: real swaps, fee splits, gross-up, preview, oracle, third-party LP |
| `FactoryHookUnit.t.sol` | admin, registration, callback auth, fee chain, volatility math via `FactoryHookHarness` |
| `FuzzHook.t.sol` | fee conservation / bounds / oracle step over fuzzed real swaps |
| `HookConfigPayload.t.sol` | schema-v2 payload validation, pipeline binding, zero-fee floor, payload fuzz |
| `LpShareSplit.t.sol` | `lpShareBps`, 3-bps floor, `SwapFeeDistributed`, `previewFee` |
| `FeeChainAdversity.t.sol` | reverting / gas-guzzling / returndata-bomb / overflowing calculators, sniper window |
| `ObserverAdversity.t.sol` | observer notifications, greedy / reverting / reentering observers, hookData bound, max config |
| `ObserverGasSkip.t.sol` | an observer cannot be skipped by under-gassing the swap |
| `AdversarialOnRegister.t.sol` | S2 reentrant `registerPool`, S1 pre-deploy poisoning of a porous extension, role mix-ups |
| `RegistrationEvents.t.sol` | `CalculatorConfigured` / `ObserverConfigured` carry the raw sub-payloads |
| `VaultNotifyGuard.t.sol` | a reverting vault cannot brick the ETH leg (`VaultNotifyFailed` redirect) |
| `PoC_LowC/LowF/LowI/LowJ_*.t.sol`, `PoC_HM09_*`, `PoC_H328_*` | the audit-refutation PoCs that target the hook |
| `PoC_H29_*`, `PoC_H364_*` | **version-specific**: the L-04 attack, splitting one trade into N swaps in one block. In `v1.0` they carry *harm* assertions and pass, because the bug is in the deployed hook. In `v1.1` they carry *FIXED* assertions |
| `PoC_L04_TruncatedTickCapPerBlock.t.sol` | **v1.1 only**: the L-04 regression suite, harness and live pool |
| `ExtensionHostViews.t.sol` | **v1.1 only**: the `IExtensionHost` views and constants the registry change added, plus `factoryOwner` / `factoryTreasury` |

### Substitutions and drops

- **Fee calculator substituted.** `ObserverAdversity.test_feeChange_notifiedOnRegimeChangeOnly` and
  `AdversarialOnRegister.test_roleSelectors_calculatorBoundAsObserver_failsTheDeploy` bind the live
  dynamic-fee calculator; here a `FixedQuoteCalculator(3000)` gives the hook the same regime change
  and the same missing `onRegisterObserver`.
  `AdversarialOnRegister.test_S1_officialExtension_gateKillsThePoisoning` tests that calculator's own
  gate rather than the hook, and is dropped.
- **Assertions about contracts outside this package dropped.** `HookConfigPayload.LpdAtTest` and the
  two `RegistrationEvents.test_deploy_emitsFeeRecipientAssigned_*` cases assert what a coin and the
  coin factory do, not what the hook does.
- **Atomic registration.** Where a test expected coin creation to revert on a bad payload, the coin
  is created first and `vm.expectRevert` is armed on `_registerCoin` — one external self-call
  wrapping `registerPool` + `initialize`, so the step is as atomic as it is live.
- `PoC_LowF.test_H281_CI4B_LiveSwapWithNoStakingVaultDoesNotRevert` points the coin's fee recipient
  at `users.creator`.
- Two mutability tweaks (`view` / `pure`) silence compiler warnings on two test functions.

### Not included

Suites that reach the hook only through contracts outside this package are not here, along with the
fuzzing harness and the fork tests.
