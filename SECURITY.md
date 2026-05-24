# Security Policy — Φ-Hook

## Supported Versions

| Version | Network | Status |
|---|---|---|
| v2 | Sepolia Testnet | ✅ Active |
| v1 | Sepolia Testnet | Legacy |
| Mainnet | — | ⏳ Post-audit only |

---

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately to:

**Email:** houarispd@gmail.com
**Subject:** `[SECURITY] phi-hook — brief description`

### What to Include

- Contract name and function affected
- Step-by-step reproduction
- Impact assessment (funds at risk? governance bypass? etc.)
- Suggested fix (optional)

### Response Timeline

| Action | Timeframe |
|---|---|
| Acknowledgment | Within 48 hours |
| Initial assessment | Within 7 days |
| Fix or mitigation | Within 30 days |
| Public disclosure | After fix is deployed |

---

## Audit Status

| Item | Status |
|---|---|
| Internal review | ✅ Complete |
| 121/121 tests | ✅ Passing |
| Fuzz testing (250K calls) | ✅ Complete |
| Independent audit | ⏳ Q3 2026 |

The protocol is deployed on Sepolia testnet only. **Do not use on mainnet until the audit is published.**

---

## Known Considerations

**Timestamp dependency**
Time-gate calculations rely on `block.timestamp`. This is standard in DeFi (Uniswap, Aave, Compound all use it). Miners can manipulate timestamps by ~15 seconds — insufficient to affect Fibonacci time-gates measured in days.

**Uniswap V4 PoolManager dependency**
Φ-Hook does not reimplement PoolManager logic. Its security depends on Uniswap V4's battle-tested core.

**Large exponent values**
Exponents above 60 periods are mathematically safe within the fixed-point implementation. Overflow protection is in place.

---

## Scope

**In scope:**
- All contracts in `src/`
- Deployment scripts in `script/`
- Test correctness in `test/`

**Out of scope:**
- Uniswap V4 core contracts (report to Uniswap)
- Front-end UI issues (open a regular issue)
- Theoretical attacks requiring >51% hash power
