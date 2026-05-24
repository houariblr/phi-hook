# Contributing to Φ-Hook

Thank you for your interest in contributing. Φ-Hook is built on mathematical immutability — contributions must respect that foundation.

---

## Core Principle

The Golden Ratio and Fibonacci sequence are **not parameters**. They are axioms. No contribution may alter the mathematical constants that define this protocol.

---

## How to Contribute

### 1. Open an Issue First

Before writing code, open an issue describing what you want to change and why. This saves everyone time.

Good issue titles:
- `[BUG] PhiRewards: dust accumulates under edge case X`
- `[TEST] Missing fuzz coverage for FeeCollector.withdraw()`
- `[DOCS] DEPLOYMENT.md missing CREATE2 salt instructions`

### 2. Fork and Branch

```bash
git fork https://github.com/houariblr/phi-hook
git checkout -b fix/your-description
```

### 3. Write Tests First

All changes require tests. We maintain 100% test pass rate. No exceptions.

```bash
# Run tests before and after your change
forge test

# Run with gas report to catch regressions
forge test --gas-report
```

### 4. Submit a Pull Request

- Clear title and description
- Reference the issue number
- Tests must pass: `forge test` — 121/121
- No changes to any mathematical constant

---

## What We Welcome

| Type | Examples |
|---|---|
| Bug fixes | Edge cases, precision issues, reentrancy vectors |
| Test coverage | Fuzz tests, invariant tests, edge cases |
| Documentation | Clearer explanations, missing steps, translations |
| Gas optimizations | Assembly improvements, storage packing |
| UI improvements | Phi Oracle interface enhancements |

## What We Do Not Accept

| Type | Reason |
|---|---|
| Changes to φ, Fibonacci values | Mathematical constants — not governance parameters |
| Governance mechanisms | Zero governance is a core invariant |
| Token inflation features | Real yield only — no inflationary mechanics |
| Unverified math changes | Requires formal proof or independent audit |

---

## Code Style

- Solidity: follow Foundry defaults (`forge fmt`)
- NatSpec on all public functions
- No magic numbers — use named constants
- Comments explain *why*, not *what*

```bash
# Format your code before submitting
forge fmt
```

---

## Questions?

Open a [discussion](https://github.com/houariblr/phi-hook/discussions) or email houarispd@gmail.com.
