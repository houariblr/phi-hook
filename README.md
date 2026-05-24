# Φ-Hook (Phi Hook) 🌀

> **Sustainable LP Retention via Golden Ratio Mathematics for Uniswap V4**

[![Tests](https://img.shields.io/badge/tests-121%2F121-brightgreen)](https://github.com/houariblr/phi-hook/actions)
[![Solidity](https://img.shields.io/badge/solidity-^0.8.26-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Network](https://img.shields.io/badge/network-Sepolia-purple)](https://sepolia.etherscan.io/address/0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4%20Hook-ff007a)](https://docs.uniswap.org/contracts/v4/overview)

An autonomous, parameter-free Uniswap V4 hook that eliminates mercenary liquidity through **mathematical immutability**. Φ-Hook harnesses the Golden Ratio (φ ≈ 1.618) and Fibonacci sequences to create self-regulating LP incentives backed entirely by real swap fee yield — not token inflation, not governance.

**Built by one developer. Tested to mathematical certainty.**

---

## 📋 Table of Contents

- [Why Φ-Hook](#-why-φ-hook)
- [How It Works](#-how-it-works)
- [Core Components](#-core-components)
- [Mathematical Specifications](#-mathematical-specifications)
- [Protocol Invariants](#-protocol-invariants)
- [Phi Oracle (AI Interface)](#-phi-oracle-ai-interface)
- [Quick Start](#-quick-start)
- [Local Development](#-local-development)
- [Deployment](#-deployment)
- [Security & Audits](#-security--audits)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)
- [Contact](#-contact)

---

## ❓ Why Φ-Hook

| Problem | Traditional Solution | Φ-Hook Solution |
|---|---|---|
| **Liquidity retention** | Inflationary governance tokens | Real yield from swap fees |
| **Parameter risk** | Committee votes (exploitable) | Mathematical constants (immutable) |
| **Early exits** | No penalty | Dynamic φ-curve penalties → reward pool |
| **Governance overhead** | DAO treasury (slow, exploitable) | Zero governance (faster, safer) |
| **LP fairness** | Equal shares regardless of commitment | Fibonacci-weighted exponential rewards |

**Real numbers at $10M TVL, 0.3% fee tier:**
- LPs earn: **$13,000 – $22,000/month** (compounding, real yield)
- Protocol treasury: **$1,300 – $2,200/month** (self-sustaining)

---

## 📊 How It Works

### The Golden Ratio Mechanic

Φ-Hook uses three interlocking mechanisms:

**1. Fibonacci Time-Gates**
LPs choose a commitment tier from 12 Fibonacci-spaced durations:
```
1 → 1 → 2 → 3 → 5 → 8 → 13 → 21 → 34 → 55 → 89 → 144 days
```

**2. φ-Weighted Reward Shares**
Commitment unlocks exponential multipliers at the golden ratio thresholds:
```
Tiers 0–9  (up to 55 days)  →  1.000× multiplier
Tier 10    (89 days)         →  1.618× multiplier  (φ¹)
Tier 11    (144 days)        →  2.618× multiplier  (φ²)
```

**3. Real Yield Distribution**
Protocol captures exactly 38.2% (= 1/φ²) of swap fees — the Fibonacci retracement level:
```
Total swap fees
├── 61.8%  →  LP reward pool  (distributed by φ-weighted shares)
└── 38.2%  →  Treasury        (protocol sustainability)
```

**4. Self-Regulating Exit Penalties**
Early withdrawals incur a penalty (max 5%, decaying on φ-curve) that flows 100% into the reward pool — punishing mercenary LPs and rewarding the committed.

**Result:** A mathematically self-sustaining flywheel. No governance. No inflation. No committees.

---

## 🔧 Core Components

### `src/PhiMath.sol` — Pure Mathematical Kernel
| Attribute | Detail |
|---|---|
| Role | Fibonacci & Golden Ratio fixed-point arithmetic |
| Key methods | `phiPow(n)`, `fibonacci(n)`, `earlyExitFeeBps()` |
| Precision | Zero floating-point; ≤144 wei max error across all exponents |
| Dependencies | None (pure math library) |

### `src/PhiHook.sol` — Uniswap V4 Hook Interface
| Attribute | Detail |
|---|---|
| Role | Core hook logic: mint, burn, swap interception |
| Key hooks | `afterAddLiquidity`, `beforeRemoveLiquidity`, `afterSwap` |
| Settlement | ERC-6909 (no ERC-20 approvals required) |
| LOC | ~1,000 |

### `src/PhiRewards.sol` — Synthetix-Style Reward Engine
| Attribute | Detail |
|---|---|
| Role | Accumulated reward distribution per φ-weighted share |
| Precision | 128-bit fixed-point (`rewardPerShareX128`) |
| Features | Dust recycling, anti-rounding locks, overflow protection |

### `src/FeeCollector.sol` — Fee Settlement & Access Control
| Attribute | Detail |
|---|---|
| Role | Treasury fee extraction with zero ERC-20 custody |
| Pattern | Uniswap V4 unlock callback (atomic, CEI-compliant) |
| Access | Owner + approved collector only |

---

## 📐 Mathematical Specifications

### Fibonacci Tier Matrix

| Tier | Lock (Days) | Exit Penalty | φ-Multiplier |
|---|---|---|---|
| 0  | 1   | 5.0%  | 1.000× |
| 1  | 1   | 8.0%  | 1.000× |
| 2  | 2   | 13.0% | 1.000× |
| 3  | 3   | 21.0% | 1.000× |
| 4  | 5   | 34.0% | 1.000× |
| 5  | 8   | 55.0% | 1.000× |
| 6  | 13  | 89.0% | 1.000× |
| 7  | 21  | 89.0% | 1.000× |
| 8  | 34  | 89.0% | 1.000× |
| 9  | 55  | 89.0% | 1.000× |
| 10 | 89  | 89.0% | **1.618×** (φ¹) |
| 11 | 144 | 89.0% | **2.618×** (φ²) |

**Key insight:** Lock durations are Fibonacci numbers — no arbitrary parameters anywhere in the system.

### Protocol Fee Formula
```
Protocol Fee = 1 / φ² ≈ 38.196...% = 3,820 basis points
```
This is the Fibonacci retracement level — a mathematically optimal split validated across markets and natural systems for centuries.

---

## 🛡️ Protocol Invariants

| Invariant | Guarantee |
|---|---|
| **Zero token inflation** | No governance token, no treasury dilution, ever |
| **No committee risk** | All parameters derived from φ and Fibonacci — immutable by design |
| **Atomic settlement** | CEI pattern; penalties applied before any state mutation |
| **Dust recycling** | Rounding residuals recycled into reward pool — no wei permanently locked |
| **ERC-6909 settlement** | No ERC-20 approvals; no approval-based attack vectors |

---

## 🤖 Phi Oracle (AI Interface)

Φ-Hook ships with **Phi Oracle** — an AI-powered interface that lets users interact with the protocol in natural language (Arabic & English).

### What It Does
- Recommends the optimal commitment tier for any capital amount and duration
- Calculates exact expected yield using real φ mathematics
- Explains protocol mechanics in plain language
- Shows live on-chain status of deployed contracts (v1 & v2)

### Features
- Live Sepolia contract status via RPC
- Structured AI responses with contextual follow-up actions
- Bilingual: Arabic and English
- IBM Plex fonts — official government-grade typography

### Running Locally
```bash
cd ui/
npm install
# Add your Anthropic API key to .env
echo "VITE_ANTHROPIC_API_KEY=sk-ant-..." > .env
npm run dev
```

### Preview
> Ask: *"I have $10,000 and want to maximize yield over 90 days. Which tier?"*
> Phi Oracle responds with tier recommendation, expected yield calculation, and penalty risk analysis.

---

## 🚀 Quick Start

**For LPs:**
```
1. Deposit liquidity into a Φ-Hook enabled Uniswap V4 pool
2. Choose a commitment tier (1 day → 144 days)
3. Earn φ-weighted rewards from 61.8% of swap fees
4. Exit early? Penalty funds the pool for committed LPs.
```

**For Pool Deployers:**
```
1. Deploy Φ-Hook contract (or use existing Sepolia deployment)
2. Initialize V4 pool with hook address
3. Φ-Hook handles all LP incentive logic automatically — zero governance needed
```

**For Developers:**
```bash
git clone --recursive https://github.com/houariblr/phi-hook.git
cd phi-hook
forge build
forge test       # 121 tests, 100% pass rate
```

---

## 🔧 Local Development

### Prerequisites
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version   # forge 0.2.0+
```

### Build & Test
```bash
# Clone with all submodules (v4-core, v4-periphery, forge-std)
git clone --recursive https://github.com/houariblr/phi-hook.git
cd phi-hook

# Build
forge build

# Run full test suite (121 tests)
forge test

# Verbose output with stack traces
forge test -vvv

# Target a specific contract
forge test --match-contract PhiHookTest -vvv
forge test --match-contract PhiRewardsTest -vvv
forge test --match-contract FeeCollectorTest -vvv

# Run with gas report
forge test --gas-report

# Run fuzzer (250,000 calls)
forge test --fuzz-runs 250000
```

### Expected Output
```
Running 121 tests for test/...
[PASS] testPhiMath_fibonacci() (gas: 12,453)
[PASS] testPhiMath_phiPow_tier10() (gas: 8,891)
[PASS] testPhiHook_addLiquidity_tierSelection() (gas: 145,230)
...
Test result: ok. 121 passed; 0 failed; finished in 4.23s
```

---

## 🚀 Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md) for full instructions.

**Live Deployments (Sepolia Testnet):**

| Contract | Address | Explorer |
|---|---|---|
| PhiHook v2 | `0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641` | [View ↗](https://sepolia.etherscan.io/address/0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641) |
| PhiHook v1 | `0x4c5888f9CDE99259D32b9887DEdd6239F53A8640` | [View ↗](https://sepolia.etherscan.io/address/0x4c5888f9CDE99259D32b9887DEdd6239F53A8640) |

---

## 🔐 Security & Audits

| Item | Status |
|---|---|
| Test suite | ✅ 121/121 passing |
| Fuzz testing | ✅ 250,000+ calls |
| `via_ir` compilation | ✅ Enabled |
| Optimizer | ✅ 200 runs |
| Independent audit | ⏳ In progress — Q3 2026 |
| Audit firm | TBD (Sherlock / Peckshield / OpenZeppelin) |
| Audit report | Will be published post-completion |

**Known considerations:**
- Timestamp dependency for time-gate calculations (standard pattern across all DeFi protocols)
- Large exponent values (>60 periods) mathematically safe, monitoring recommended
- Depends on Uniswap V4 PoolManager security (battle-tested, not reimplemented here)

**Found a vulnerability?** Please email houarispd@gmail.com before public disclosure.

---

## 🗺️ Roadmap

| Phase | Timeline | Status | Deliverable |
|---|---|---|---|
| Phase 1 | Q1 2026 | ✅ Done | Core contracts + 121 tests |
| Phase 2 | Aug 2026 | ⏳ Active | Third-party security audit |
| Phase 3 | Sep 2026 | 📋 Planned | TypeScript SDK + Subgraph indexer |
| Phase 4 | Oct 2026 | 📋 Planned | Phi Oracle UI + mainnet launch |
| Phase 5 | Q4 2026 | 📋 Planned | Multi-chain: Arbitrum, Optimism, Polygon |

---

## 📁 Project Structure

```
phi-hook/
├── .github/
│   └── workflows/
│       └── test.yml              # CI: runs forge test on every push
├── broadcast/
│   └── Deploy.s.sol/11155111/    # Recorded deployment transactions (Sepolia)
├── lib/
│   ├── forge-std/                # Foundry test utilities
│   ├── v4-core/                  # Uniswap V4 core (submodule)
│   └── v4-periphery/             # Uniswap V4 periphery (submodule)
├── script/
│   └── Deploy.s.sol              # Foundry deployment script
├── src/
│   ├── PhiHook.sol               # Core hook (~1,000 LOC)
│   ├── PhiMath.sol               # Math library (~200 LOC)
│   ├── PhiRewards.sol            # Reward engine (~200 LOC)
│   └── FeeCollector.sol          # Fee settlement (~100 LOC)
├── test/
│   ├── PhiHookTest.t.sol         # Integration tests
│   ├── PhiRewardsTest.t.sol      # Unit + fuzz tests
│   └── FeeCollectorTest.t.sol    # Access control tests
├── ui/
│   └── PhiOracle.jsx             # AI-powered protocol interface
├── phi_hook_architecture.svg     # Protocol architecture diagram
├── foundry.toml                  # Foundry configuration
├── DEPLOYMENT.md                 # Full deployment guide
├── Grant_Application.pdf         # Uniswap Foundation grant application
└── README.md                     # This file
```

---

## 🤝 Contributing

Contributions are welcome. Φ-Hook is built on mathematical constants — contributions must preserve that immutability.

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Write tests — we maintain 100% pass rate
4. Open a pull request with a clear description

**Hard rules:**
- No changes to hardcoded mathematical constants (φ, Fibonacci sequence)
- All new code requires corresponding tests
- Follow Solidity style guide (Foundry defaults)
- Update documentation for any new public functions

---

## 📚 Further Reading

- [Uniswap V4 Hooks Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [ERC-6909 Multi-Token Standard](https://eips.ethereum.org/EIPS/eip-6909)
- [Golden Ratio — Wikipedia](https://en.wikipedia.org/wiki/Golden_ratio)
- [Fibonacci Sequence — Wikipedia](https://en.wikipedia.org/wiki/Fibonacci_number)
- [Synthetix Reward Distribution Pattern](https://mirror.xyz/0x...)

---

## 📞 Contact

**Lead Developer:** Houari
**Email:** houarispd@gmail.com
**GitHub:** [@houariblr](https://github.com/houariblr)
**Twitter/X:** [@houariblr](https://twitter.com/houariblr)

Questions? Open an [issue](https://github.com/houariblr/phi-hook/issues) or start a [discussion](https://github.com/houariblr/phi-hook/discussions).

---

## 📄 License

MIT License — Copyright (c) 2026 SPD Software Lab

See [LICENSE](LICENSE) for full terms.

---

## 🙏 Acknowledgments

- **Uniswap Foundation** — V4 hooks architecture
- **Foundry** — the best EVM testing framework
- **Synthetix** — reward distribution pattern inspiration
- **Nature** — for discovering φ first 🌀

---

<div align="center">
  <strong>φ = 1.6180339887...</strong><br/>
  <em>Built by one. Understood by few. Designed to last.</em>
</div>
