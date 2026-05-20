// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {PhiHook} from "../src/PhiHook.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract MockPM {
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCB(msg.sender).unlockCallback(data);
    }
    function take(Currency, address, uint256) external {}
}
interface IUnlockCB { function unlockCallback(bytes calldata) external returns (bytes memory); }

contract PhiHookTest is Test {
    using CurrencyLibrary for Currency;

    PhiHook hook;
    address pm;
    address lp  = address(0xBEEF);
    address lp2 = address(0xCAFE);

    PoolKey  key;
    bytes32  poolId;
    int24 constant TL = -60;
    int24 constant TU =  60;

    function setUp() public {
        pm   = address(new MockPM());
        hook = new PhiHook(IPoolManager(pm), address(this));
        key  = PoolKey({
            currency0:   Currency.wrap(address(0x1)),
            currency1:   Currency.wrap(address(0x2)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       hook
        });
        poolId = keccak256(abi.encode(key));
    }

    function _add(address _lp, uint128 liq, uint8 tier) internal {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: int256(uint256(liq)), salt: 0
        });
        bytes memory hd = tier == hook.DEFAULT_FIB_TIER()
            ? bytes("") : abi.encodePacked(tier);
        vm.prank(pm);
        hook.afterAddLiquidity(_lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), hd);
    }

    function _remove(address _lp, uint128 liq, int128 proc)
        internal returns (BalanceDelta)
    {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: -int256(uint256(liq)), salt: 0
        });
        BalanceDelta lpDelta = BalanceDelta.wrap((int256(proc) << 128) | 0);
        vm.prank(pm);
        hook.beforeRemoveLiquidity(_lp, key, p, "");
        vm.prank(pm);
        (, BalanceDelta d) = hook.afterRemoveLiquidity(
            _lp, key, p, lpDelta, BalanceDelta.wrap(0), "");
        return d;
    }

    function _swap(int128 a0) internal {
        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: int256(a0), sqrtPriceLimitX96: 0
        });
        BalanceDelta sd = BalanceDelta.wrap((int256(a0) << 128) | 0);
        vm.prank(pm);
        hook.afterSwap(address(0), key, sp, sd, "");
    }

    function _swapParams() internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(10_000e18), sqrtPriceLimitX96: 0
        });
    }

    // ─── registration ─────────────────────────────────────────────
    function test_register_new_position() public {
        _add(lp, 1000e18, 3);
        PhiHook.LPPosition memory pos = hook.getPosition(lp, poolId, TL, TU);
        assertEq(pos.fibTier,   3);
        assertEq(pos.liquidity, 1000e18);
        assertEq(pos.entryTime, block.timestamp);
    }

    function test_register_custom_tier() public {
        _add(lp, 500e18, 7);
        assertEq(hook.getPosition(lp, poolId, TL, TU).fibTier, 7);
    }

    function test_invalid_tier_reverts() public {
        uint8 def = hook.DEFAULT_FIB_TIER();
        require(def == 3);
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: int256(uint256(uint128(100e18))), salt: 0
        });
        vm.expectRevert(
            abi.encodeWithSelector(PhiHook.PhiHook__InvalidFibTier.selector, uint8(12)));
        vm.prank(pm);
        hook.afterAddLiquidity(lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0),
            abi.encodePacked(uint8(12)));
    }

    function test_add_on_existing_preserves_entry_time() public {
        _add(lp, 1000e18, 3);
        uint64 t = hook.getPosition(lp, poolId, TL, TU).entryTime;
        vm.warp(block.timestamp + 5 days);
        _add(lp, 500e18, 3);
        assertEq(hook.getPosition(lp, poolId, TL, TU).entryTime, t);
        assertEq(hook.getPosition(lp, poolId, TL, TU).liquidity, 1500e18);
    }

    function test_add_on_existing_preserves_tier() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 1 days);
        _add(lp, 500e18, 3);
        assertEq(hook.getPosition(lp, poolId, TL, TU).fibTier, 7);
    }

    // ─── timeToGate ───────────────────────────────────────────────
    function test_timeToGate_full_at_entry() public {
        _add(lp, 100e18, 3);
        assertEq(hook.timeToGate(lp, poolId, TL, TU), 3 days);
    }

    function test_timeToGate_zero_after_gate() public {
        _add(lp, 100e18, 3);
        vm.warp(block.timestamp + 3 days + 1);
        assertEq(hook.timeToGate(lp, poolId, TL, TU), 0);
    }

    function test_timeToGate_decreasing() public {
        _add(lp, 100e18, 3);
        uint256 t1 = hook.timeToGate(lp, poolId, TL, TU);
        vm.warp(block.timestamp + 1 days);
        assertTrue(hook.timeToGate(lp, poolId, TL, TU) < t1);
    }

    // ─── currentMultiplier ────────────────────────────────────────
    function test_multiplier_one_at_entry() public {
        _add(lp, 100e18, 3);
        assertEq(hook.currentMultiplier(lp, poolId, TL, TU), PhiMath.SCALE);
    }

    function test_multiplier_phi_after_one_T60() public {
        _add(lp, 100e18, 3);
        vm.warp(block.timestamp + PhiMath.T60 + 1);
        assertApproxEqAbs(hook.currentMultiplier(lp, poolId, TL, TU), PhiMath.PHI, 2);
    }

    function test_multiplier_phi_sq_after_two_T60() public {
        _add(lp, 100e18, 3);
        vm.warp(block.timestamp + 2 * PhiMath.T60 + 1);
        assertApproxEqAbs(
            hook.currentMultiplier(lp, poolId, TL, TU),
            PhiMath.PHI + PhiMath.SCALE, 4);
    }

    // ─── early exit ───────────────────────────────────────────────
    function test_early_exit_charges_fee() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        _remove(lp, 1000e18, 500e18);
        (,, uint256 rewardBalance) = hook.rewardPools(poolId);
        assertTrue(rewardBalance > 0);
    }

    function test_early_exit_fee_in_delta() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        BalanceDelta d = _remove(lp, 1000e18, 500e18);
        assertTrue(d.amount0() < 0);
    }

    function test_no_fee_after_gate() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 21 days + 1);
        BalanceDelta d = _remove(lp, 1000e18, 500e18);
        assertEq(d.amount0(), 0);
        assertEq(hook.accruedFees(poolId), 0);
    }

    function test_fee_decreases_with_time() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        BalanceDelta d1 = _remove(lp, 1000e18, 500e18);
        uint256 fee1 = uint256(uint128(-d1.amount0()));

        _add(lp2, 1000e18, 7);
        vm.warp(block.timestamp + 15 days);
        BalanceDelta d2 = _remove(lp2, 1000e18, 500e18);
        uint256 fee2 = uint256(uint128(-d2.amount0()));
        assertTrue(fee1 > fee2);
    }

    function test_fee_applied_on_real_tokens_not_L() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        BalanceDelta d1 = _remove(lp, 1000e18, 10e18);
        uint256 feeSmall = uint256(uint128(-d1.amount0()));

        _add(lp2, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        BalanceDelta d2 = _remove(lp2, 1000e18, 500e18);
        uint256 feeLarge = uint256(uint128(-d2.amount0()));
        assertTrue(feeLarge > feeSmall);
    }

    // ─── no position ──────────────────────────────────────────────
    function test_no_position_reverts() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU, liquidityDelta: -1e18, salt: 0
        });
        vm.expectRevert(PhiHook.PhiHook__PositionNotFound.selector);
        vm.prank(pm);
        hook.beforeRemoveLiquidity(address(0xDEAD), key, p, "");
    }

    // ─── onlyPoolManager ──────────────────────────────────────────
    function test_non_manager_reverts() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU, liquidityDelta: 1e18, salt: 0
        });
        vm.expectRevert();
        hook.afterAddLiquidity(lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    // ─── afterSwap ────────────────────────────────────────────────
    function test_afterSwap_accrues_fee() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18); // a0 > 0 → token0 into pool

        uint256 lpFee       = uint256(10_000e18) * 3000 / 1_000_000;
        uint256 protocolFee = lpFee * 3820 / 10_000;
        uint256 expected    = protocolFee * (10_000 - 6180) / 10_000;
        assertEq(hook.accruedFees(poolId), expected);
    }

    function test_afterSwap_no_fee_on_positive_delta() public {
        _add(lp, 1000e18, 3);
        SwapParams memory sp = SwapParams({
            zeroForOne: false, amountSpecified: int256(10_000e18), sqrtPriceLimitX96: 0
        });
        // both a0=0, a1=0 → no fee
        vm.prank(pm);
        hook.afterSwap(address(0), key, sp, BalanceDelta.wrap(0), "");
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── collectFees ──────────────────────────────────────────────
    function test_collect_only_owner() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        vm.expectRevert(PhiHook.PhiHook__NotAuthorized.selector);
        vm.prank(address(0xBAD));
        hook.collectFees(poolId, Currency.wrap(address(0x1)), address(0xBAD));
    }

    function test_collect_zero_reverts() public {
        vm.expectRevert(PhiHook.PhiHook__ZeroFees.selector);
        hook.collectFees(poolId, Currency.wrap(address(0x1)), address(this));
    }

    function test_collect_clears_balance() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        assertTrue(hook.accruedFees(poolId) > 0);
        try hook.collectFees(
            poolId, Currency.wrap(address(0x1)), address(this)
        ) {} catch {}
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── setCollector ─────────────────────────────────────────────
    function test_setCollector_only_owner() public {
        vm.expectRevert(PhiHook.PhiHook__NotAuthorized.selector);
        vm.prank(address(0xBAD));
        hook.setCollector(address(0x123));
    }

    function test_setCollector_updates() public {
        hook.setCollector(address(0x123));
        assertEq(hook.approvedCollector(), address(0x123));
    }

    // ─── HOOK_FLAGS ───────────────────────────────────────────────
    function test_hook_flags_value() public view {
        assertEq(hook.HOOK_FLAGS(), uint160(0x641));
    }
}
