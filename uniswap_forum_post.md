# Φ-Hook: LP retention using Fibonacci gates and φ-weighted rewards — looking for feedback

Been building a V4 hook for the past few months and I think it's at a point where it's worth sharing. Not looking to pitch anything, just want real feedback from people who know V4 internals.

---

## The core idea

DeFi liquidity is mercenary because nothing makes staying *mathematically* better than leaving. ve-tokenomics and emission programs paper over this but don't solve it — they just move the problem.

My approach: use the golden ratio (φ = 1.618) and Fibonacci sequence as the actual mechanism. Not as branding — as the literal parameters.

**Fibonacci gates:** LPs choose a commitment tier when they add liquidity. The gate durations follow Fibonacci: 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144 days. Exit before the gate and you pay a penalty that decays along a φ-curve. Wait until the gate and you pay nothing.

**φ reward multiplier:** Every 60 days of continuous liquidity, your reward share multiplies by φ. So periods=0 is 1×, periods=1 is 1.618×, periods=2 is 2.618× (because φ² = φ+1), and so on. The self-referential property of φ means the curve is mathematically stable — you can't game it by timing.

**Fee split:** 38.2% of the LP fee (= 1/φ²) goes to the protocol. Of that: 61.8% flows to the reward pool distributed to committed LPs, 38.2% to treasury. The percentages are φ-derived, not arbitrary.

No new token. All yield is backed by real swap fees.

---

## What's built

Four contracts:

- `PhiMath.sol` — pure integer fixed-point library. φ^n via binary exponentiation, Fibonacci sequence, φ-curve fee decay. Zero floating point, all verified against Python Decimal(prec=50) ground truth.
- `PhiHookV2.sol` — the hook itself. Handles afterAddLiquidity, beforeRemoveLiquidity, afterRemoveLiquidity (with returnDelta), afterSwap.
- `PhiRewards.sol` — Synthetix-style accumulator with φ-weighted shares. Q128 precision.
- `FeeCollector.sol` — access control façade over the hook's collectFees. Thin on purpose.

Fee settlement is fully V4-native: fees accumulate as ERC-6909 claims inside PoolManager (via `mint()` in the hook callbacks), then redeemed via `burn() + take()` inside a dedicated `unlock()` context. No ERC-20 approvals anywhere.

**Tests: 89/89 passing**

| Suite | Count |
|---|---|
| PhiMathTest | 19 |
| PhiRewardsTest | 19 |
| PhiHookTest | 26 |
| PoolInitializerTest | 9 |
| FeeCollectorTest | 16 |

Sepolia deployments:
- v1: `0x4c5888f9CDE99259D32b9887DEdd6239F53A8640`
- v2: `0xc5474f...c641`

Repo: https://github.com/houariblr/phi-hook

---

## What I'm not sure about

A few things I'd genuinely like input on:

**1. The fee rate**

Protocol takes 38.2% of the LP fee. On a 0.3% pool that's ~0.115% of volume going to the protocol. Is that too aggressive for LPs to accept? I picked it because 1/φ² is mathematically motivated, but I'm aware that doesn't mean LPs will like it.

**2. Partial removals**

When an LP partially removes liquidity, I re-register their remaining shares via `registerOrUpdate()` rather than calling `exit()`. This means they keep accruing rewards on the remaining position. I think this is correct behavior but it changes the incentive structure — partial exit no longer resets the clock.

**3. Hook address mining**

Current flags: afterAddLiquidity (bit 10) + beforeRemoveLiquidity (bit 9) + afterRemoveLiquidity with returnDelta (bit 0) + afterSwap (bit 6) = 0x641. The CREATE2 salt search took a while on Sepolia. Anyone run into issues with this on mainnet?

**4. What's missing before this is production-ready**

I know: invariant tests (in progress), external audit (not done), frontend (not done). Anything else obvious I'm missing from people who've shipped hooks?

---

Appreciate any feedback, harsh or otherwise.

— Houari
