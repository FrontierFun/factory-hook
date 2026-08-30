# Introduction
A comprehensive security review was performed from August 17, 2026 to August 25, 2026 for Frontier's V2 contracts (`feature/contractsV2`).

This document carries the findings that concern `FactoryHook`, the contract published in this repository. The findings on the other V2 contracts are in the full report, which is not shared here.

# About Frontier
Frontier is a token-launch protocol. Creators deploy bonding-curve coins that graduate into a Uniswap V4 pool governed by `FactoryHook`. Post-graduation, swap fees are split across the protocol, an optional staking vault, and a fee recipient. V2 adds a POL distributor, a direct-seed path, and official fee-calculator extensions (dynamic fee and sniper tax).

# Disclaimer

This security review represents a time-bound analysis of the provided code and information. While comprehensive efforts were made to identify vulnerabilities, I do not guarantee the absence of all security issues or the complete safety of the smart contract system. The findings presented are for informational purposes only and should not be considered financial, legal, or investment advice.

This review does not constitute an endorsement of the project. I explicitly disclaim all liability for any damages or losses resulting from the use of or reliance on this report, including those stemming from smart contract exploitation or any changes made after this audit.

The project team bears full responsibility for decisions made based on this report and should seek additional professional guidance as needed. By utilizing this report, the team acknowledges and agrees to these terms.

# About Sammy
<div style="display: flex; align-items: center; gap: 30px;">
  <img src="https://pbs.twimg.com/profile_images/1773362588308410368/NVb9-oI6_400x400.jpg" height="160" style="border-radius: 50%; object-fit: cover;"/>
  <div>
    <p>
      X: <a href="https://x.com/sammyaudits">@sammyaudits</a><br>
      Telegram: <a href="https://t.me/SammyAudits">@SammyAudits</a>
    </p>
  </div>
</div>

<br>

Sammy is a leading security researcher in the Web3 space with extensive expertise in smart contract auditing. As a founding security researcher at [Blackthorn](https://blackthorn.xyz), Sammy brings battle-tested experience to complex protocol assessments.

With multiple top finishes in competitive audit contests on platforms like [Sherlock](https://sherlock.xyz) and [Cantina](https://cantina.xyz), Sammy has established a reputation for identifying critical vulnerabilities that other auditors miss.

Throughout his career, Sammy has collaborated with numerous protocols to strengthen their security posture before deployment, helping teams implement robust, secure systems while maintaining their intended functionality.

# Scope

- **Public Hook Repository**: https://github.com/FrontierFun/factory-hook

- **Audited Version (v1.0)**: [`e6571bd71ad0c545c0c6c72c96791a4c9fc7915c`](https://github.com/FrontierFun/factory-hook/commit/e6571bd71ad0c545c0c6c72c96791a4c9fc7915c)

- **Fix Review Version (v1.1, Current Head)**: [`a269603d40991ff83cc9da427c961a4bb0c83341`](https://github.com/FrontierFun/factory-hook/commit/a269603d40991ff83cc9da427c961a4bb0c83341)

- **Final Commit**: NA

### Files in Scope

| File Path | Status | LOC |
|-----------|--------|-----|
| src/hook/FactoryHook.sol | Modified | 544 |

The review covered eleven V2 contracts. Only the hook is listed here, since it is the only one this repository publishes.

# Severity Classification


- **Critical** - Severe loss of funds, complete compromise of project availability, or significant violation of protocol invariants.

- **High** - High impact on funds, major disruption to project functionality or substantial violation of protocol invariants.

- **Medium** - Moderate risk affecting a noticeable portion of funds, project availability or partial violation of protocol invariants.

- **Low** - Low impact on a small portion of funds (e.g. dust amount), minor disruptions to service or minor violation of protocol invariants.

- **Informational** - Negligible risk with no direct impact on funds, availability or protocol invariants.

# Summary

| Severity       | Total | Fixed | Acknowledged |
| -------------- | ----- | ----- | ------------ |
| Critical       | 0     | 0     | 0            |
| High           | 0     | 0     | 0            |
| Medium         | 1     | 0     | 1            |
| Low            | 1     | 1     | 0            |
| Informational  | 0     | 0     | 0            |


<br>

| # | Title | Severity | Status |
| - | ----- | -------- | ------ |
| [M-01](#m-01) | `PROTOCOL_PAUSED` does not halt graduated Uniswap V4 swaps | Medium | Acknowledged |
| [L-04](#l-04) | Truncated-tick per-swap cap is manipulable within a single block | Low | Fixed |

# Findings

## Medium Findings

<a name="m-01"></a>
### [M-01] `PROTOCOL_PAUSED` does not halt graduated Uniswap V4 swaps

**Description:**<br>
`BCTokenFactory.setProtocolPaused` is the protocol's emergency switch. `factory.deploy` and bonding-curve `buy` / `sell` honor `PROTOCOL_PAUSED`. Graduated trading does not.

`FactoryHook._beforeSwap` only checks that the coin has graduated:

```solidity
if (!IBCToken(state.coin).isLPd()) revert NotLPd();
```

The hook never reads `factory.PROTOCOL_PAUSED()`. The `_beforeSwap` comment still describes the order as “graduation gate → halt gate → volatility update”, but there is no halt gate in the function body.

Once a coin is LPd, its Uniswap V4 pool is the live venue. Pausing the protocol therefore stops new launches and curve trading only. Already-graduated pools — where liquidity and fees actually sit — keep swapping.

**Impact:**<br>
An emergency pause does not stop AMM trading, fee distribution, vault notifies, or observer callbacks on graduated coins. The control that operators would use to halt the system leaves the main market live.

**Recommended Mitigation:**<br>
Read `IBCTokenFactory(BC_TOKEN_FACTORY).PROTOCOL_PAUSED()` in `_beforeSwap` (and any other post-graduation entry) and revert when set. Remove or update the stale “halt gate” comment so it matches the implemented policy.

**Acknowledged in v1.1:**<br>
This is the intended behavior. Once a coin graduates, its Uniswap V4 pool must stay tradable under every condition: no owner action, and no protocol state, may block swaps on a live pool. `PROTOCOL_PAUSED` is scoped to what the protocol still controls, new launches and bonding-curve trading, and stops at graduation by design. The stale “halt gate” comment in `_beforeSwap` is the only part that will be corrected, so the code reads as the policy it implements.

## Low Findings

<a name="l-04"></a>
### [L-04] Truncated-tick per-swap cap is manipulable within a single block

**Description:**<br>
`FactoryHook._afterSwap` always calls `_checkpointSwap`, which moves `truncatedTick` by at most `MAX_ABS_TICK_MOVE` (9116) **per swap**:

```solidity
if (tick - truncatedTick > MAX_ABS_TICK_MOVE) {
    truncatedTick += MAX_ABS_TICK_MOVE;
} else if (tick - truncatedTick < -MAX_ABS_TICK_MOVE) {
    truncatedTick -= MAX_ABS_TICK_MOVE;
} else {
    truncatedTick = tick;
}
```

There is no `if (block.timestamp != lastObservation)` / per-block gate. Canonical Uniswap truncated oracles apply this damping at most once per block. Here an actor can issue multiple swaps in one block and displace the recorded tick by `9116 × swaps-per-block`.

`observe()` exposes `truncatedTick` and the `tickCumulative` built from it. The hook's own fee path uses the volatility accumulator, not this oracle, so the impact is on external consumers.

**Impact:**<br>
Any integrator consuming `observe()` can be shown a truncated tick that has been pushed well beyond the intended single-observation ceiling inside one block.

**Recommended Mitigation:**<br>
Gate the truncated-tick write to at most once per block (key on `block.number` or `block.timestamp`), so `MAX_ABS_TICK_MOVE` is a per-block ceiling.

**Fixed in v1.1:** [`a269603d40991ff83cc9da427c961a4bb0c83341`](https://github.com/FrontierFun/factory-hook/commit/a269603d40991ff83cc9da427c961a4bb0c83341)<br>
The reviewed implementation anchors every same-block checkpoint to the recorded tick at the start of the block. Split swaps therefore cannot compound `MAX_ABS_TICK_MOVE`, while the final in-block tick is still recorded within that fixed envelope. Unit, fuzz, and live-pool regression tests cover split swaps, same-block round trips, initialization, and advancement across blocks.

