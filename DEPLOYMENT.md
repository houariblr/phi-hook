# Deployment Guide — Φ-Hook

> Complete instructions for deploying Phi-Hook to Sepolia testnet or Ethereum mainnet.

---

## Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify
forge --version   # 0.2.0+
cast --version
```

---

## Environment Setup

Create a `.env` file in the project root (never commit this):

```bash
cp .env.example .env
```

Edit `.env`:
```env
# Required
PRIVATE_KEY=0x...your_deployer_private_key...
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_PROJECT_ID

# Optional (for contract verification)
ETHERSCAN_API_KEY=your_etherscan_api_key

# Mainnet (when ready)
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_PROJECT_ID
```

Load the environment:
```bash
source .env
```

---

## Sepolia Testnet Deployment

### Step 1 — Get Sepolia ETH

You need ~0.05 ETH for deployment gas. Get it from:
- [Alchemy Faucet](https://sepoliafaucet.com/)
- [Infura Faucet](https://www.infura.io/faucet/sepolia)
- [Chainlink Faucet](https://faucets.chain.link/sepolia)

### Step 2 — Verify Uniswap V4 PoolManager Address

Sepolia PoolManager: `0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A`

Confirm the address is live:
```bash
cast code 0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A \
  --rpc-url $SEPOLIA_RPC_URL
# Should return bytecode (not 0x)
```

### Step 3 — Deploy Contracts

```bash
# Dry run first (simulation, no gas spent)
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --simulate

# If simulation passes, deploy for real
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

Expected output:
```
== Logs ==
  PhiMath deployed:        0x...
  FeeCollector deployed:   0x...
  PhiRewards deployed:     0x...
  PhiHook deployed:        0x...
  Hook flags verified:     OK
  All contracts deployed and linked.
```

### Step 4 — Verify Deployment

```bash
# Check PhiHook is deployed
cast code 0xYOUR_HOOK_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# Check PoolManager is wired correctly
cast call 0xYOUR_HOOK_ADDRESS "poolManager()" --rpc-url $SEPOLIA_RPC_URL

# Check protocol fee (should return 3820 = 38.20%)
cast call 0xYOUR_HOOK_ADDRESS "PROTOCOL_FEE_BPS()" --rpc-url $SEPOLIA_RPC_URL
```

---

## Manual Contract Deployment (Step by Step)

If you prefer deploying each contract individually:

```bash
# 1. Deploy PhiMath (no constructor args)
forge create src/PhiMath.sol:PhiMath \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# Save output address as PHIMATH_ADDRESS

# 2. Deploy FeeCollector
forge create src/FeeCollector.sol:FeeCollector \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# Save output address as FEECOLLECTOR_ADDRESS

# 3. Deploy PhiRewards
forge create src/PhiRewards.sol:PhiRewards \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# Save output address as PHIREWARDS_ADDRESS

# 4. Deploy PhiHook (requires PoolManager address)
POOL_MANAGER=0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A

forge create src/PhiHook.sol:PhiHook \
  --constructor-args $POOL_MANAGER \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Hook Address Mining

Uniswap V4 hooks require specific address prefixes based on the hooks they implement. If your deployment address doesn't satisfy hook flags:

```bash
# Mine a valid hook address
forge script script/MineHookAddress.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

The script uses `CREATE2` with a salt to find an address satisfying:
```
flags = AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_SWAP
```

---

## Existing Deployments (Sepolia)

| Contract | Address | Etherscan |
|---|---|---|
| PhiHook v2 | `0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641` | [View ↗](https://sepolia.etherscan.io/address/0xc5474f8Ea5D7Db1533be81DeA2EC99d09f5Ac641) |
| PhiHook v1 | `0x4c5888f9CDE99259D32b9887DEdd6239F53A8640` | [View ↗](https://sepolia.etherscan.io/address/0x4c5888f9CDE99259D32b9887DEdd6239F53A8640) |

---

## Initializing a V4 Pool with Φ-Hook

After deployment, create a pool that uses your hook:

```solidity
// In your deployment script or a setup script:

IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
    currency0: Currency.wrap(address(token0)),
    currency1: Currency.wrap(address(token1)),
    fee: 3000,                          // 0.3% swap fee
    tickSpacing: 60,
    hooks: IHooks(PHI_HOOK_ADDRESS)     // Your deployed PhiHook
});

// Initial sqrt price (1:1 ratio)
uint160 sqrtPriceX96 = 79228162514264337593543950336;

poolManager.initialize(poolKey, sqrtPriceX96);
```

---

## Post-Deployment Checklist

```
[ ] PhiHook deployed and verified on Etherscan
[ ] Hook flags match required prefix (check with cast)
[ ] PoolManager address confirmed in hook storage
[ ] Test pool initialized successfully
[ ] At least one test LP position added
[ ] afterSwap hook fires on test swap
[ ] FeeCollector owner set to deployer address
[ ] Protocol fee verified: 3820 bps
[ ] Phi Oracle UI updated with new hook address
```

---

## Mainnet Deployment

> ⚠️ **Do not deploy to mainnet before the security audit is complete (Q3 2026).**

When the audit is complete:

1. Replace `SEPOLIA_RPC_URL` with `MAINNET_RPC_URL`
2. Update PoolManager address to mainnet value
3. Increase gas limit in `foundry.toml` if needed
4. Run with `--slow` flag to avoid nonce issues:

```bash
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --slow \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

---

## Troubleshooting

**"Hook address does not match expected flags"**
→ You need to mine a valid CREATE2 address. Run `MineHookAddress.s.sol`.

**"Insufficient funds"**
→ Get Sepolia ETH from a faucet. Deployment costs ~0.01–0.05 ETH.

**"PoolManager not found"**
→ Confirm the PoolManager address is correct for your network.

**"forge script: command not found"**
→ Run `foundryup` to update your Foundry installation.

**Etherscan verification fails**
→ Wait 30 seconds after deployment and retry. Etherscan indexing can lag.

---

## Support

Open an [issue](https://github.com/houariblr/phi-hook/issues) or contact houarispd@gmail.com.
