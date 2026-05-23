# φ-Hook

> 60% of Uniswap LPs lose money within 30 days.  
> φ-Hook fixes this. No token. No governance. Just math.

[![Tests](https://img.shields.io/badge/tests-121%20passing-brightgreen)](./test)
[![Solidity](https://img.shields.io/badge/solidity-0.8.24-blue)](https://soliditylang.org)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Sepolia](https://img.shields.io/badge/Sepolia-deployed-purple)](https://sepolia.etherscan.io/address/0x4c5888f9CDE99259D32b9887DEdd6239F53A8640)

---

## The Problem

Data from Loesch et al. (2021) on real Uniswap V3 pools:

| Holding Period | % of LPs | Net P&L     |
|---------------|----------|-------------|
| 1–7 days      | 35%      | **−0.10% ❌** |
| 8–30 days     | 25%      | **−0.20% ❌** |
| 31–90 days    | 18%      | **+0.40% ✅** |
| 91–180 days   | 12%      | **+1.30% ✅** |
| 181+ days     | 10%      | **+4.30% ✅** |

**60% of LPs exit within 30 days — and lose money doing it.**

The math is clear: staying longer wins. But there is no incentive to stay.  
Uniswap treats a 7-day LP and a 180-day LP identically.  
φ-Hook changes that.

---

## The Result

Simulation (N=1,000 LPs, $10M pool, base fee = 0.3%):

| Metric              | Without Hook | With φ-Hook | Delta   |
|--------------------|-------------|-------------|---------|
| LPs retained @30d  | 41%         | 68%         | +27pp   |
| LPs retained @180d | 21%         | 44%         | +23pp   |
| Net return @180d   | +5.27%      | +14.00%     | **+2.66×** |
| TVL retained @180d | $5.2M       | $8.8M       | +$3.6M  |

---

## How It Works

### 1. Fibonacci Time-Gates

LPs choose a commitment tier when adding liquidity:

```
Tier 3  →   3 days
Tier 5  →   8 days
Tier 7  →  21 days
Tier 8  →  34 days
Tier 9  →  55 days
Tier 10 →  89 days
Tier 11 → 144 days  ← maximum
```

Leave early → pay a φ-decay penalty (max 5%).  
That penalty goes directly into the reward pool for LPs who stayed.

### 2. φ-Weighted Rewards

Every 60 days of continuous liquidity adds one φ-period.  
Reward shares grow geometrically:

```
shares = liquidity × φ^periods

Period 0 →  60 days  → 1.000× (baseline)
Period 1 → 120 days  → 1.618× (φ¹)
Period 2 → 180 days  → 2.618× (φ²)
Period 3 → 240 days  → 4.236× (φ³)
Period 4 → 300 days  → 6.854× (φ⁴)
```

An LP who holds for 180 days earns **2.618×** the reward shares  
of an LP who holds for 60 days — with identical liquidity.

### 3. Protocol Fee Split

61.8% of swap fees flow to the reward pool.

The remaining 38.2% goes to treasury (`1/φ²`) — the golden-ratio retracement level.  
The protocol speaks one mathematical language throughout.

```
Swap fee revenue
├── 61.8% → LP reward pool  (φ-weighted distribution)
└── 38.2% → Treasury        (1/φ² = Fibonacci retracement)
```

---

## Why φ Specifically?

φ is the only positive number where `φ² = φ + 1`.

This means:
- The reward curve is self-consistent — tier N+1 is always φ× tier N
- No parameter committee can "tune" it without breaking the math
- The same constant governs time-gates, reward multipliers, and fee splits

**The math is the mechanism.**

---

## Architecture

```
PhiHook.sol          ← Uniswap V4 Hook
├── PhiMath.sol      ← φ^n, fibonacci(n), earlyExitFeeBps
├── PhiRewards.sol   ← Synthetix-style φ-weighted distribution
└── FeeCollector.sol ← Treasury facade
```

**Hook flags:** `afterAddLiquidity` + `beforeRemoveLiquidity` +  
`afterRemoveLiquidity` + `afterSwap` = `0x641`

**No token. No oracle. No governance. No admin key for math constants.**

---

## Security

| Invariant | Status |
|-----------|--------|
| `withdrawn ≤ added` (solvency) | ✅ 1000 runs × 50000 calls |
| `pending ≤ totalAdded` (boundedness) | ✅ 1000 runs × 50000 calls |
| `rewardPerShare` non-decreasing | ✅ 1000 runs × 50000 calls |
| `totalShares` consistent | ✅ 1000 runs × 50000 calls |
| Fee never negative | ✅ fuzz 256 runs |
| φ^n no overflow (n ≤ 144) | ✅ verified |

**Rounding:** Fixed-point Q128 arithmetic. 1-wei truncation drift  
capped in `_harvest` — standard pattern used in Synthetix, Uniswap.

**Independent audit:** Planned Q3 2026.

---

## Test Coverage

```
forge test

121 tests passing, 0 failing

PhiMath        19 tests  (fuzz: 256 runs each)
PhiRewards     19 tests
PhiRewardsInvariant  5 tests  (1000 runs × 50000 calls each)
PhiHook        26 tests
PhiHookV2      27 tests
FeeCollector   14 tests
PoolInitializer 9 tests
Counter         2 tests
```

---

## Quick Start

```bash
git clone --recursive https://github.com/houariblr/phi-hook
cd phi-hook
forge test
```

**Deployed on Sepolia:**  
`0x4c5888f9CDE99259D32b9887DEdd6239F53A8640`

**Add liquidity with commitment tier:**
```solidity
// hookData = abi.encodePacked(uint8 fibTier)
// tier 8 = 34-day gate
bytes memory hookData = abi.encodePacked(uint8(8));
poolManager.modifyLiquidity(poolKey, params, hookData);
```

---

## Upgrade Safety

Every struct reserves storage gaps for future fields:
```solidity
struct RewardPool {
    uint256 rewardPerShareX128;
    uint256 totalShares;
    uint256 balance;
    uint256[5] __gap;  // reserved for v2
}
```

V4 hook addresses encode permission flags deterministically —  
standard proxy patterns are incompatible by design.  
V2 roadmap: `PhiVault` eternal storage separating LP accounting  
from hook logic, enabling migration without LP re-deposits.

---

## References

- Loesch et al. (2021). *Impermanent Loss in Uniswap v3.* [arXiv:2111.09192](https://arxiv.org/abs/2111.09192)
- Kyle, A.S. (1985). *Continuous Auctions and Insider Trading.* Econometrica.
- [Uniswap V4 Hook Architecture](https://docs.uniswap.org/contracts/v4/overview)

---

## Contact

**GitHub:** [@houariblr](https://github.com/houariblr)  
**X:** [@houari_spd](https://twitter.com/houari_spd)  
**Email:** houarispd@gmail.com

MIT License © 2026
