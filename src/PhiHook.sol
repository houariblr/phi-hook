// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks}          from "../lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}    from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}         from "../lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {SafeCallback}    from "../lib/v4-periphery/src/base/SafeCallback.sol";
import {PhiMath}         from "./PhiMath.sol";

/// @title  PhiHook
/// @notice Uniswap V4 Hook — Fibonacci time-gates + golden-ratio reward multiplier.
///         Treasury-only fee model (no LP reward distribution).
///         For the full φ-reward distribution upgrade, see PhiHookV2.
///
/// @dev    posKey = keccak256(lp, poolId, tickLower, tickUpper)
///         One LP may hold multiple ranges per pool, each independent.
///
///         Stack-depth strategy: external hooks unpack calldata structs to plain
///         value types then delegate to internal helpers.
///         `via_ir = true` in foundry.toml provides a global compiler backstop.
contract PhiHook is IHooks, SafeCallback {
    using CurrencyLibrary for Currency;

    // ─── Events ───────────────────────────────────────────────────

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
    }

    // ─── Constants ────────────────────────────────────────────────

    uint8   public constant MAX_FIB_TIER       = 11;
    uint256 public constant MAX_EARLY_EXIT_BPS = 500;
    uint8   public constant DEFAULT_FIB_TIER   = 3;

    // afterAddLiquidity(1<<10) + beforeRemoveLiquidity(1<<9)
    // + afterSwap(1<<6) + afterRemoveLiquidityReturnsDelta(1<<0) = 0x641
    uint160 public constant HOOK_FLAGS = uint160(0x641);

    // ─── Storage ──────────────────────────────────────────────────

    mapping(bytes32 => LPPosition) public positions;
    mapping(bytes32 => uint256)    public accruedFees;
    mapping(bytes32 => uint256)    private _pendingExitFeeBps;

    address public immutable owner;
    address public approvedCollector;

    // ─── Constructor ──────────────────────────────────────────────

    constructor(IPoolManager _manager) SafeCallback(_manager) {
        owner = msg.sender;
    }

    // ─── IHooks stubs ─────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    { return IHooks.afterInitialize.selector; }

    function beforeAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata
    ) external pure override returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    // ─── afterAddLiquidity ────────────────────────────────────────

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
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
        ModifyLiquidityParams calldata params,
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
        ModifyLiquidityParams calldata params,
        BalanceDelta delta, BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (
            IHooks.afterRemoveLiquidity.selector,
            _afterRemoveCore(
                sender, _poolId(key),
                params.tickLower, params.tickUpper,
                delta.amount0(),
                uint128(uint256(-int256(params.liquidityDelta)))
            )
        );
    }

    // ─── Swap ─────────────────────────────────────────────────────

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external pure override returns (bytes4, BeforeSwapDelta, uint24)
    { return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0); }

    /// @notice Accrue 38.2% (1/φ²) of the pool LP fee as protocol treasury.
    /// @dev    protocolFee = (|amount0| × pool.fee / 1e6) × PROTOCOL_FEE_BPS / 10_000
    ///         ERC-6909 claims minted so collectFees → burn+take works.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            uint256 lpFee      = (uint256(uint128(-amount0)) * key.fee) / 1_000_000;
            uint256 protocolFee = (lpFee * PhiMath.PROTOCOL_FEE_BPS) / 10_000;
            if (protocolFee > 0) {
                bytes32 poolId = _poolId(key);
                accruedFees[poolId] += protocolFee;
                poolManager.mint(address(this), key.currency0.toId(), protocolFee);
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

    /// @dev burn ERC-6909 claims → take real tokens.  Net delta = 0. ✓
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

    /// @notice Withdraw treasury fees.
    /// @dev    CEI: accruedFees zeroed before unlock.
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
            recipient: recipient
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
        uint8 periods = uint8((block.timestamp - pos.entryTime) / PhiMath.T60);
        if (periods > PhiMath.N_MAX_INV) periods = PhiMath.N_MAX_INV;
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
        } else {
            uint128 newTotal = pos.liquidity + added;
            pos.liquidity  = newTotal;
            pos.lastUpdate = uint64(block.timestamp);
            emit LiquidityIncreased(sender, posKey, added, newTotal);
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
            uint8 periods = uint8(elapsed / PhiMath.T60);
            if (periods > PhiMath.N_MAX_INV) periods = PhiMath.N_MAX_INV;
            pos.periods = periods;
            emit RewardAccrued(sender, posKey, periods, PhiMath.phiPow(periods));
        }
    }

    function _afterRemoveCore(
        address sender, bytes32 poolId,
        int24   tickLower, int24 tickUpper,
        int128  proceeds0,   // delta.amount0() — real token proceeds to LP
        uint128 removing
    ) internal returns (BalanceDelta) {
        bytes32 posKey = _posKey(sender, poolId, tickLower, tickUpper);

        uint256 feeBps = _pendingExitFeeBps[posKey];
        _pendingExitFeeBps[posKey] = 0;

        uint256 fee;
        if (feeBps > 0 && proceeds0 > 0) {
            fee = (uint256(int256(proceeds0)) * feeBps) / 10_000;
            if (fee > 0) {
                accruedFees[poolId] += fee;
                emit EarlyExitFeeCharged(sender, posKey, feeBps, fee);
            }
        }

        LPPosition storage pos = positions[posKey];
        if (pos.liquidity > 0) {
            if (removing > pos.liquidity) revert PhiHook__LiquidityUnderflow();
            uint128 newTotal = pos.liquidity - removing;
            pos.liquidity  = newTotal;
            pos.lastUpdate = uint64(block.timestamp);
            emit LiquidityDecreased(sender, posKey, removing, newTotal);
            if (newTotal == 0) delete positions[posKey];
        }

        return fee > 0
            ? toBalanceDelta(-int128(int256(fee)), 0)
            : BalanceDelta.wrap(0);
    }

    // ─── Helpers ──────────────────────────────────────────────────

    function _poolId(PoolKey calldata key) internal pure returns (bytes32)
    { return keccak256(abi.encode(key)); }

    function _posKey(address lp, bytes32 poolId, int24 tickLower, int24 tickUpper)
        internal pure returns (bytes32)
    { return keccak256(abi.encodePacked(lp, poolId, tickLower, tickUpper)); }
}
