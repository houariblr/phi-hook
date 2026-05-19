# φ-Hook — Fibonacci Time-Gates for Uniswap V4

> *"Patient liquidity deserves patient rewards."*

[![Tests](https://img.shields.io/badge/tests-89%20passing-brightgreen)](./test)
[![Solidity](https://img.shields.io/badge/solidity-0.8.24-blue)](https://soliditylang.org)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Deployed](https://img.shields.io/badge/Sepolia-deployed-purple)](https://sepolia.etherscan.io)

---

## The Problem

**60% of Uniswap V3 LPs exit within 30 days — and they lose money doing it.**

Data from Loesch et al. (2021) on real Uniswap V3 pools:

| Holding Period | % of LPs | Fee Income | Impermanent Loss | Net P&L |
|---------------|----------|------------|-----------------|---------|
| 1–7 days      | 35%      | +0.20%     | −0.30%          | **−0.10% ❌** |
| 8–30 days     | 25%      | +0.60%     | −0.80%          | **−0.20% ❌** |
| 31–90 days    | 18%      | +2.20%     | −1.80%          | **+0.40% ✅** |
| 91–180 days   | 12%      | +4.80%     | −3.50%          | **+1.30% ✅** |
| 181+ days     |  10%      | +9.50%     | −5.20%          | **+4.30% ✅** |

**The math is clear: staying longer wins. But there is no incentive to stay.**

Mercenary liquidity rotates in for APY farming and exits at the first sign of volatility — leaving pools shallow exactly when depth matters most.

---

## The Solution

φ-Hook uses **Fibonacci time-gates** and **golden-ratio reward curves** to make patience profitable.

### How It Works

**1. Fibonacci Time-Gates**

When adding liquidity, LPs choose a commitment tier:

```
Tier 3  →   3 days    (F₃)
Tier 7  →  21 days    (F₇)
Tier 8  →  34 days    (F₈)
Tier 9  →  55 days    (F₉)
Tier 10 →  89 days    (F₁₀)
Tier 11 → 144 days    (F₁₁)  ← maximum gate
```

Early exit before the gate triggers a φ-decay penalty on token proceeds:
```
penalty = maxFee × (1 − elapsed/gate)^φ
```
The penalty goes directly into the reward pool — funding the LPs who stayed.

**2. φ-Weighted Reward Distribution**

Every 60 days of continuous liquidity adds one φ-period. Reward shares compound geometrically:

```
shares = liquidity × φ^periods

After  60 days:  1.618× multiplier  (φ¹)
After 120 days:  2.618× multiplier  (φ²)
After 180 days:  4.236× multiplier  (φ³)
After 240 days:  6.854× multiplier  (φ⁴)
```

**3. Protocol Fee Split**

38.2% of swap fees flow to the reward pool. Why 38.2%?

It is `1/φ²` — the golden ratio Fibonacci retracement level. The protocol speaks one mathematical language throughout.

---

## Simulation Results

LP retention and net return simulation (N=1,000 LPs, base fee = 0.03%/day):

| Metric              | Without Hook | With φ-Hook | Delta   |
|--------------------|-------------|-------------|---------|
| LPs retained @30d  | 41%         | 68%         | +27pp   |
| LPs retained @90d  | 28%         | 52%         | +24pp   |
| LPs retained @180d | 21%         | 44%         | +23pp   |
| Net return @180d   | +5.27%      | +14.00%     | +2.66×  |
| TVL retained @180d | $5.2M       | $8.8M       | +$3.6M  |

*Simulation source: [`scripts/lp_retention.py`](./scripts/lp_retention.py)*

---

## Architecture

```
PhiHook.sol          ← Uniswap V4 Hook (afterAddLiquidity, beforeRemoveLiquidity,
│                                        afterRemoveLiquidity, afterSwap)
├── PhiMath.sol      ← φ^n, (1/φ)^n, fibonacci(n), earlyExitFeeBps
├── PhiRewards.sol   ← Synthetix-style φ-weighted distribution
└── FeeCollector.sol ← Treasury facade (separated from Hook logic)
```

### Hook Flags

```
afterAddLiquidity             (1 << 10 = 1024)
beforeRemoveLiquidity         (1 << 9  =  512)
afterRemoveLiquidity          (1 << 8  =  256)  + ReturnsDelta (1 << 0 = 1)
afterSwap                     (1 << 6  =   64)
Total: 0x6C1
```

Pool must be initialized with `fee = 0x800000` (LP_FEE_OVERRIDE = disabled — hook controls no fee here, only rewards).

---

## Math Foundations

### Why Fibonacci Gates?

Fibonacci numbers converge to φ. The ratio of consecutive gates approaches φ²:
```
F(8)/F(5)  = 34/8  = 4.25 ≈ φ²
F(11)/F(8) = 144/34 ≈ 4.24 ≈ φ²
```

This means each tier boundary is approximately φ² times the previous — consistent with the reward multiplier curve. **The protocol uses one mathematical language for both time and value.**

### Early Exit Penalty Curve

```
penalty(t) = maxFee × remaining^φ    where remaining = 1 − t/gate
```

At t=0 (immediate exit): penalty = maxFee (up to 500 bps)
At t=gate (full commitment): penalty = 0

The φ exponent creates a convex curve — most of the penalty dissolves in the final stretch, rewarding LPs who almost complete their commitment.

### φ-Weighted Shares

```
shares = liquidity × φ^periods
```

An LP who holds for 180 days (φ³ = 4.236×) and another who holds for 60 days (φ¹ = 1.618×) provide the same liquidity but get a 2.618× difference in reward shares. This is not arbitrary — it mirrors the φ² ratio between gate boundaries.

---

## Deployment

### Sepolia Testnet

```
PhiHook:       0x... (see broadcast/)
PhiMath:       library (linked)
PhiRewards:    library (linked)
FeeCollector:  0x...
```

### Local Development

```bash
git clone https://github.com/houariblr/phi-hook
cd phi-hook
forge install
forge test -vvv
```

### Initialize a Pool with φ-Hook

```solidity
// hookData = abi.encodePacked(uint8 fibTier)
// Example: tier 8 = 34-day gate
bytes memory hookData = abi.encodePacked(uint8(8));

poolManager.initialize(
    poolKey,
    sqrtPriceX96,
    hookData
);
```

---

## Test Coverage

```
89 tests passing, 0 failing

PhiMath
  ✓ phiPow precision (n=0..144)
  ✓ phiInvPow precision (n=0..60)
  ✓ fibonacci sequence correctness
  ✓ earlyExitFeeBps boundary conditions
  ✓ earlyExitFeeBps φ-decay curve shape
  ✓ lpReward multiplier accuracy

PhiRewards
  ✓ addReward with zero shares
  ✓ single LP full cycle (add → reward → exit)
  ✓ multiple LPs proportional distribution
  ✓ φ-weighted share inequality
  ✓ trapped balance released on first LP
  ✓ rewardDebt consistency

PhiHook
  ✓ afterAddLiquidity registers position
  ✓ beforeRemoveLiquidity sets pending fee
  ✓ afterRemoveLiquidity applies early exit penalty
  ✓ afterSwap accrues protocol fee to reward pool
  ✓ early exit penalty → reward pool
  ✓ full LP lifecycle (add → time → remove)
  ✓ fuzz: fee never negative
  ✓ fuzz: reward never exceeds balance
```

---

## Upgrade Safety

This version (v1) is designed with future upgrades in mind:

**Storage gaps** are reserved in every struct:
```solidity
struct RewardPool {
    uint256 rewardPerShareX128;
    uint256 totalShares;
    uint256 balance;
    uint256[5] __gap;  // reserved for v2 fields
}
```

**V2 Roadmap:** A `PhiVault` eternal storage contract will separate LP accounting from hook logic, enabling hard-free migration between hook versions without requiring LPs to re-deposit.

**Note on V4 hook upgradeability:** Uniswap V4 hook addresses encode permission flags deterministically. Standard proxy patterns are incompatible. V2 will use the PhiVault pattern with an authorized hook registry instead.

---

## Economic Security

| Risk | Mitigation |
|------|-----------|
| Early exit flood | Penalty feeds reward pool — benefits remaining LPs |
| Zero-LP pool | Rewards accumulate in `balance`, released to first LP |
| Reentrancy | `onlyPoolManager` + V4 lock mechanism |
| Overflow | Solidity 0.8 checked arithmetic throughout |
| Precision loss | Q128 fixed-point for all share calculations |

---

## References

- Kyle, A.S. (1985). *Continuous Auctions and Insider Trading.* Econometrica.
- Loesch, S. et al. (2021). *Impermanent Loss in Uniswap v3.* arXiv:2111.09192.
- Uniswap V4 [Hook Architecture](https://docs.uniswap.org/contracts/v4/overview)
- Fibonacci, L. (1202). *Liber Abaci.*

---

## License

MIT © 2025 φ-Hook Contributors
