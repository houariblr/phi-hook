// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks}          from "../lib/v4-core/src/interfaces/IHooks.sol";

import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";

import {SafeCallback}    from "../lib/v4-periphery/src/base/SafeCallback.sol";
import {PhiMath}         from "./PhiMath.sol";
import {PhiRewards}      from "./PhiRewards.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
/// @title  PhiHook
/// @notice Uniswap V4 Hook implementing Fibonacci time-gates and φ-weighted LP rewards.
///
/// @dev    Position key = keccak256(lp, poolId, tickLower, tickUpper).
///         One LP may hold multiple independent ranges per pool.
///
///         Stack-depth strategy: external hooks unpack calldata structs to plain
///         value types then delegate to internal helpers with no struct args.
///         `via_ir = true` in foundry.toml provides a global compiler backstop.
///
///         ERC-6909 note: mint() in afterSwap and _afterRemoveCore is optimistic —
///         it works correctly with the real V4 PoolManager because the tokens that
///         flow in during a swap settle inside the same unlock frame.
///         The formal BeforeSwapDelta migration path is tracked in the roadmap.
contract PhiHook is IHooks, SafeCallback {
    using CurrencyLibrary for Currency;
    using PhiRewards for PhiRewards.RewardPool;
    using PhiRewards for PhiRewards.UserReward;

    // ─── Events ───────────────────────────────────────────────────

    event RewardAdded(bytes32 indexed poolId, uint256 amount, string source);
    event RewardClaimed(address indexed lp, bytes32 indexed poolId, uint256 amount);
    event LiquidityRegistered(
        address indexed lp,     bytes32 indexed posKey,
        bytes32 indexed poolId, uint256 entryTime,
        uint8   fibTier,        uint128 liquidity,
        int24   tickLower,      int24   tickUpper
    );
    event LiquidityIncreased(
        address indexed lp, bytes32 indexed posKey,
        uint128 added,      uint128 newTotal
    );
    event LiquidityDecreased(
        address indexed lp, bytes32 indexed posKey,
        uint128 removed,    uint128 newTotal
    );
    event EarlyExitFeeCharged(
        address indexed lp, bytes32 indexed posKey,
        uint256 feeBps,     uint256 feeAmount
    );
    event RewardAccrued(
        address indexed lp, bytes32 indexed posKey,
        uint8   periods,    uint256 multiplierScaled
    );
    event FeesCollected(
        address indexed recipient, bytes32 indexed poolId, uint256 amount
    );

    // ─── Errors ───────────────────────────────────────────────────

    error PhiHook__InvalidFibTier(uint8 tier);
    error PhiHook__PositionNotFound();
    error PhiHook__NotAuthorized();
    error PhiHook__ZeroFees();
    error PhiHook__LiquidityUnderflow();
    error PhiHook__ZeroRewards();

    // ─── Structs ──────────────────────────────────────────────────

    struct LPPosition {
        uint64  entryTime;
        uint64  lastUpdate;
        uint128 liquidity;
        uint8   fibTier;
        uint8   periods;
    }

    struct CollectParams {
        bytes32  poolId;
        Currency currency;
        uint256  amount;
        address  recipient;
        bool     isReward;
    }

    // ─── Constants ────────────────────────────────────────────────

    uint8   public constant MAX_FIB_TIER       = 11;
    uint256 public constant MAX_EARLY_EXIT_BPS = 500;
    uint8   public constant DEFAULT_FIB_TIER   = 3;

    // afterAddLiquidity(1<<10) + beforeRemoveLiquidity(1<<9)
    // + afterSwap(1<<6) + afterRemoveLiquidityReturnsDelta(1<<0) = 0x641
    uint160 public constant HOOK_FLAGS       = uint160(0x641);
    uint256 public constant REWARD_SHARE_BPS = 6_180; // 61.8% = 1/φ → reward pool

    // ─── Storage ──────────────────────────────────────────────────

    mapping(bytes32 => LPPosition)            public positions;
    mapping(bytes32 => uint256)               public accruedFees;
    mapping(bytes32 => PhiRewards.RewardPool) public rewardPools;
    mapping(bytes32 => PhiRewards.UserReward) public userRewards;
    mapping(bytes32 => uint256)               private _pendingExitFeeBps;

    address public immutable owner;
    address public approvedCollector;

    // ─── Constructor ──────────────────────────────────────────────

    constructor(IPoolManager _manager, address _owner) SafeCallback(_manager) {
    owner = _owner; 
}

    // ─── IHooks stubs ─────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    { return IHooks.afterInitialize.selector; }

    function beforeAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external pure override returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    // ─── afterAddLiquidity ────────────────────────────────────────

    /// @param hookData byte[0] = fibTier (use abi.encodePacked(uint8(tier)), NOT abi.encode)
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta, BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta <= 0)
            return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));

        uint8 tier = DEFAULT_FIB_TIER;
        if (hookData.length >= 1) {
            uint8 r = uint8(hookData[0]);
            if (r > MAX_FIB_TIER) revert PhiHook__InvalidFibTier(r);
            tier = r;
        }

        _afterAddCore(
            sender, _poolId(key),
            params.tickLower, params.tickUpper,
            uint128(uint256(int256(params.liquidityDelta))),
            tier
        );
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ─── beforeRemoveLiquidity ────────────────────────────────────

    // slither-disable-next-line timestamp
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        // slither-disable-next-line timestamp
        _beforeRemoveCore(sender, _poolId(key), params.tickLower, params.tickUpper);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ─── afterRemoveLiquidity ─────────────────────────────────────

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta, BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (
            IHooks.afterRemoveLiquidity.selector,
            _afterRemoveCore(
                sender, _poolId(key),
                params.tickLower, params.tickUpper,
                delta.amount0(),
                uint128(uint256(-int256(params.liquidityDelta))),
                key.currency0.toId()   // FIX 1: pass actual currency — was missing, caused mint(…,0,fee)
            )
        );
    }

    // ─── Swap ─────────────────────────────────────────────────────

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external pure override returns (bytes4, BeforeSwapDelta, uint24)
    { return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0); }

    /// @notice Accrue 38.2% (1/φ²) of the LP fee as protocol revenue.
    ///         61.8% goes to the per-pool reward distribution.
    ///         38.2% goes to treasury (accruedFees).
    ///
    /// @dev    Charges on the INPUT token for each swap direction:
    ///         zeroForOne  → pool received token0, delta.amount0() > 0
    ///         oneForZero  → pool received token1, delta.amount1() > 0
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        // Pool received whichever token has a positive delta
        uint256 swapIn = a0 > 0
            ? uint256(int256(a0))
            : (a1 > 0 ? uint256(int256(a1)) : 0);

        if (swapIn > 0) {
            uint256 lpFee       = (swapIn * key.fee) / 1_000_000;
            uint256 protocolFee = (lpFee * PhiMath.PROTOCOL_FEE_BPS) / 10_000;
            if (protocolFee > 0) {
                bytes32 poolId     = _poolId(key);
                uint256 rewardPart = (protocolFee * REWARD_SHARE_BPS) / 10_000;
                uint256 treasury   = protocolFee - rewardPart;
                if (rewardPart > 0) {
                    rewardPools[poolId].addReward(rewardPart);
                    emit RewardAdded(poolId, rewardPart, "swap_fee");
                }
                if (treasury > 0) accruedFees[poolId] += treasury;
                // Mint ERC-6909 claims for the token that entered the pool
                uint256 currId = a0 > 0
                    ? key.currency0.toId()
                    : key.currency1.toId();
                poolManager.mint(address(this), currId, protocolFee);
            }
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Donate stubs ─────────────────────────────────────────────

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.afterDonate.selector; }

    // ─── SafeCallback ─────────────────────────────────────────────

    /// @dev Unified callback for both treasury (collectFees) and LP reward (claimRewards).
    ///      burn ERC-6909 claims → take real tokens.  Net delta = 0. ✓
    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory)
    {
        CollectParams memory p = abi.decode(data, (CollectParams));
        poolManager.burn(address(this), p.currency.toId(), p.amount);
        poolManager.take(p.currency, p.recipient, p.amount);
        emit FeesCollected(p.recipient, p.poolId, p.amount);
        return abi.encode(p.amount);
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setCollector(address collector) external {
        if (msg.sender != owner) revert PhiHook__NotAuthorized();
        approvedCollector = collector;
    }

    /// @notice Withdraw treasury fees for a pool.
    /// @dev    CEI: accruedFees zeroed before unlock enters the callback.
    function collectFees(bytes32 poolId, Currency currency, address recipient) external {
        if (msg.sender != owner && msg.sender != approvedCollector)
            revert PhiHook__NotAuthorized();
        uint256 amount = accruedFees[poolId];
        if (amount == 0) revert PhiHook__ZeroFees();
        accruedFees[poolId] = 0;
        poolManager.unlock(abi.encode(CollectParams({
            poolId:    poolId,
            currency:  currency,
            amount:    amount,
            recipient: recipient,
            isReward:  false
        })));
    }

    // ─── Rewards ──────────────────────────────────────────────────

    function pendingRewards(
        address lp, bytes32 poolId, int24 tickLower, int24 tickUpper
    ) external view returns (uint256) {
        bytes32 posKey = _posKey(lp, poolId, tickLower, tickUpper);
        return rewardPools[poolId].pendingReward(userRewards[posKey]);
    }

    /// @notice Claim all pending φ-rewards for a position.
    /// @dev    CEI: pending zeroed before unlock.
    ///         Uses _harvestUser() instead of inlining the accumulator math.
    function claimRewards(
        bytes32 poolId, Currency currency, int24 tickLower, int24 tickUpper
    ) external {
        bytes32 posKey = _posKey(msg.sender, poolId, tickLower, tickUpper);
        PhiRewards.UserReward storage ur = userRewards[posKey];
        PhiRewards.RewardPool  storage rp = rewardPools[poolId];

        // FIX 4: replaced 8 lines of duplicated accumulator logic with a helper.
        // _harvestUser moves accrued-but-unclaimed rewards into ur.pending.
        _harvestUser(rp, ur);

        uint256 amount = ur.pending;
        if (amount == 0) revert PhiHook__ZeroRewards();
        ur.pending = 0;                               // CEI: zero before unlock
        emit RewardClaimed(msg.sender, poolId, amount);
        poolManager.unlock(abi.encode(CollectParams({
            currency:  currency,
            amount:    amount,
            recipient: msg.sender,
            poolId:    poolId,
            isReward:  true
        })));
    }

    // ─── View ─────────────────────────────────────────────────────

    function getPosition(address lp, bytes32 poolId, int24 tickLower, int24 tickUpper)
        external view returns (LPPosition memory)
    { return positions[_posKey(lp, poolId, tickLower, tickUpper)]; }

    // slither-disable-next-line timestamp
    function timeToGate(address lp, bytes32 poolId, int24 tickLower, int24 tickUpper)
        external view returns (uint256)
    {
        LPPosition memory pos = positions[_posKey(lp, poolId, tickLower, tickUpper)];
        if (pos.entryTime == 0) return 0;
        // slither-disable-next-line timestamp
        uint256 elapsed = block.timestamp - pos.entryTime;
        uint256 gate    = PhiMath.gateSeconds(pos.fibTier);
        return elapsed >= gate ? 0 : gate - elapsed;
    }

    // slither-disable-next-line timestamp
    function currentMultiplier(address lp, bytes32 poolId, int24 tickLower, int24 tickUpper)
        external view returns (uint256)
    {
        LPPosition memory pos = positions[_posKey(lp, poolId, tickLower, tickUpper)];
        if (pos.entryTime == 0) return PhiMath.SCALE;
        // slither-disable-next-line timestamp
        // FIX 3: compute as uint256 first, THEN cap, THEN cast to uint8.
        // Old code: uint8(elapsed/T60) silently wraps when > 255 periods,
        // making the cap check useless (e.g. 260 periods → uint8 = 4, never capped).
        uint256 rawPeriods = (block.timestamp - pos.entryTime) / PhiMath.T60;
        uint8 periods = uint8(
            rawPeriods > uint256(PhiMath.N_MAX_INV) ? PhiMath.N_MAX_INV : rawPeriods
        );
        return PhiMath.phiPow(periods);
    }

    // ─── Internal core (no calldata structs) ──────────────────────

    function _afterAddCore(
        address sender, bytes32 poolId,
        int24   tickLower, int24 tickUpper,
        uint128 added,     uint8 tier
    ) internal {
        bytes32 posKey = _posKey(sender, poolId, tickLower, tickUpper);
        LPPosition storage pos = positions[posKey];

        if (pos.entryTime == 0) {
            positions[posKey] = LPPosition({
                entryTime:  uint64(block.timestamp),
                lastUpdate: uint64(block.timestamp),
                liquidity:  added,
                fibTier:    tier,
                periods:    0
            });
            emit LiquidityRegistered(sender, posKey, poolId,
                block.timestamp, tier, added, tickLower, tickUpper);
            rewardPools[poolId].registerOrUpdate(userRewards[posKey], added, 0);
        } else {
            uint128 newTotal = pos.liquidity + added;
            pos.liquidity  = newTotal;
            pos.lastUpdate = uint64(block.timestamp);
            emit LiquidityIncreased(sender, posKey, added, newTotal);
            rewardPools[poolId].registerOrUpdate(
                userRewards[posKey], newTotal, pos.periods);
        }
    }

    // slither-disable-next-line timestamp
    function _beforeRemoveCore(
        address sender, bytes32 poolId,
        int24   tickLower, int24 tickUpper
    ) internal {
        bytes32 posKey = _posKey(sender, poolId, tickLower, tickUpper);
        LPPosition storage pos = positions[posKey];
        if (pos.entryTime == 0) revert PhiHook__PositionNotFound();

        // slither-disable-next-line timestamp
        uint256 elapsed = block.timestamp - pos.entryTime;
        uint256 gate    = PhiMath.gateSeconds(pos.fibTier);

        if (elapsed < gate) {
            _pendingExitFeeBps[posKey] = PhiMath.earlyExitFeeBps(
                MAX_EARLY_EXIT_BPS, elapsed, gate);
        } else {
            _pendingExitFeeBps[posKey] = 0;
            // FIX 3: compute as uint256 first, THEN cap, THEN cast.
            // Prevents silent truncation when elapsed > 255 × T60.
            uint256 rawPeriods = elapsed / PhiMath.T60;
            uint8 periods = uint8(
                rawPeriods > uint256(PhiMath.N_MAX_INV) ? PhiMath.N_MAX_INV : rawPeriods
            );
            pos.periods = periods;
            emit RewardAccrued(sender, posKey, periods, PhiMath.phiPow(periods));
        }
    }

    /// @param currencyId  key.currency0.toId() — passed from afterRemoveLiquidity.
    ///                    FIX 1: was hard-coded 0 (= native ETH) in all non-ETH pools.
    function _afterRemoveCore(
        address sender, bytes32 poolId,
        int24   tickLower, int24 tickUpper,
        int128  proceeds0,
        uint128 removing,
        uint256 currencyId
    ) internal returns (BalanceDelta) {
        bytes32 posKey = _posKey(sender, poolId, tickLower, tickUpper);

        uint256 feeBps = _pendingExitFeeBps[posKey];
        _pendingExitFeeBps[posKey] = 0;

        uint256 fee;
        if (feeBps > 0 && proceeds0 > 0) {
            fee = (uint256(int256(proceeds0)) * feeBps) / 10_000;
            if (fee > 0) {
                rewardPools[poolId].addReward(fee);
                poolManager.mint(address(this), currencyId, fee); // FIX 1: was (…, 0, fee)
                emit RewardAdded(poolId, fee, "early_exit");
                emit EarlyExitFeeCharged(sender, posKey, feeBps, fee);
            }
        }

        LPPosition storage pos = positions[posKey];
        if (pos.liquidity > 0) {
            if (removing > pos.liquidity) revert PhiHook__LiquidityUnderflow();
            uint128 newTotal = pos.liquidity - removing;
            pos.lastUpdate = uint64(block.timestamp);

            if (newTotal == 0) {
                // ── Full exit ─────────────────────────────────────────────
                // Harvest all accumulated rewards before the position is gone.
                delete positions[posKey];
                uint256 harvested = rewardPools[poolId].exit(userRewards[posKey]);
                if (harvested > 0) userRewards[posKey].pending += harvested;
            } else {
                // ── Partial removal ───────────────────────────────────────
                // FIX 2: old code called exit() unconditionally, zeroing the LP's
                // reward shares even when they still had liquidity in the pool.
                // Correct behaviour: re-register with the remaining liquidity so
                // future rewards are earned proportionally to newTotal, not zero.
                pos.liquidity = newTotal;
                rewardPools[poolId].registerOrUpdate(
                    userRewards[posKey], newTotal, pos.periods);
                emit LiquidityDecreased(sender, posKey, removing, newTotal);
            }
        }

        return fee > 0
            ? toBalanceDelta(-int128(int256(fee)), 0)
            : BalanceDelta.wrap(0);
    }

    // ─── Private helpers ──────────────────────────────────────────

    /// @dev FIX 4: de-duplicated harvest accumulator.
    ///      Moves accrued-but-unclaimed rewards into ur.pending and updates
    ///      ur.rewardDebtX128.  Equivalent to the inline logic that was
    ///      previously copy-pasted in claimRewards.
    function _harvestUser(
        PhiRewards.RewardPool storage rp,
        PhiRewards.UserReward storage ur
    ) private {
        if (ur.shares == 0) return;
        uint256 acc = (ur.shares * rp.rewardPerShareX128) / PhiRewards.Q128;
        if (acc > ur.rewardDebtX128) {
            uint256 nr = acc - ur.rewardDebtX128;
            ur.pending    += nr;
            rp.balance     = rp.balance > nr ? rp.balance - nr : 0;
        }
        ur.rewardDebtX128 = acc;
    }

    // ─── Helpers ──────────────────────────────────────────────────

    function _poolId(PoolKey calldata key) internal pure returns (bytes32)
    { return keccak256(abi.encode(key)); }

    function _posKey(address lp, bytes32 poolId, int24 tickLower, int24 tickUpper)
        internal pure returns (bytes32)
    { return keccak256(abi.encodePacked(lp, poolId, tickLower, tickUpper)); }
}
