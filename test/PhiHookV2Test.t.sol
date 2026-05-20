// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {PhiHook} from "../src/PhiHook.sol";
import {PhiRewards} from "../src/PhiRewards.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract MockPMV2 {
    uint256 public mintCount;
    uint256 public burnCount;
    uint256 public takeCount;
    uint256 public lastMintAmount;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;
    bool    public unlockCalled;

    function mint(address, uint256, uint256 amount) external {
        mintCount++;
        lastMintAmount = amount;
    }
    function burn(address, uint256, uint256) external { burnCount++; }
    function take(Currency, address to, uint256 amount) external {
        takeCount++;
        lastTakeRecipient = to;
        lastTakeAmount    = amount;
    }
    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCalled = true;
        return IUnlockV2(msg.sender).unlockCallback(data);
    }
}

interface IUnlockV2 {
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

contract PhiHookV2Test is Test {
    PhiHook  hook;
    MockPMV2 pm;

    address lp  = address(0xBEEF);
    address lp2 = address(0xCAFE);
    address lp3 = address(0xDEAD);

    PoolKey  key;
    bytes32  poolId;
    Currency cur0;

    int24 constant TL = -60;
    int24 constant TU =  60;

    function setUp() public {
        pm   = new MockPMV2();
        hook = new PhiHook(IPoolManager(address(pm)), address(this));
        cur0 = Currency.wrap(address(0x1));
        key  = PoolKey({
            currency0:   cur0,
            currency1:   Currency.wrap(address(0x2)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       hook
        });
        poolId = keccak256(abi.encode(key));
    }

    // ─── helpers ──────────────────────────────────────────────────
    function _add(address _lp, uint128 liq, uint8 tier) internal {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: int256(uint256(liq)), salt: 0
        });
        bytes memory hd = tier == hook.DEFAULT_FIB_TIER()
            ? bytes("") : abi.encodePacked(tier);
        vm.prank(address(pm));
        hook.afterAddLiquidity(_lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), hd);
    }

    function _remove(address _lp, uint128 liq, int128 proceeds0)
        internal returns (BalanceDelta)
    {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: -int256(uint256(liq)), salt: 0
        });
        BalanceDelta lpDelta = BalanceDelta.wrap(
            (int256(proceeds0) << 128) | int256(0));
        vm.prank(address(pm));
        hook.beforeRemoveLiquidity(_lp, key, p, "");
        vm.prank(address(pm));
        (, BalanceDelta d) = hook.afterRemoveLiquidity(
            _lp, key, p, lpDelta, BalanceDelta.wrap(0), "");
        return d;
    }

    function _swap(int128 amount0In) internal {
        SwapParams memory sp = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount0In),
            sqrtPriceLimitX96: 0
        });
        // a0 > 0 → pool received token0
        BalanceDelta sd = BalanceDelta.wrap(
            (int256(amount0In) << 128) | int256(0));
        vm.prank(address(pm));
        hook.afterSwap(address(0), key, sp, sd, "");
    }

    function _rewardBalance() internal view returns (uint256) {
        (,, uint256 bal) = hook.rewardPools(poolId);
        return bal;
    }

    function _totalShares() internal view returns (uint256) {
        (, uint256 ts,) = hook.rewardPools(poolId);
        return ts;
    }

    // ─── registration ─────────────────────────────────────────────
    function test_v2_register_position() public {
        _add(lp, 1000e18, 3);
        PhiHook.LPPosition memory pos = hook.getPosition(lp, poolId, TL, TU);
        assertEq(pos.liquidity, 1000e18);
        assertEq(pos.fibTier,   3);
    }

    function test_v2_register_sets_reward_shares() public {
        _add(lp, 1000e18, 0);
        assertEq(_totalShares(), 1000e18);
    }

    function test_v2_add_on_existing_accumulates() public {
        _add(lp, 1000e18, 3);
        vm.warp(block.timestamp + 5 days);
        _add(lp, 500e18, 3);
        assertEq(hook.getPosition(lp, poolId, TL, TU).liquidity, 1500e18);
    }

    // ─── afterSwap ────────────────────────────────────────────────
    function test_v2_swap_splits_fee_correctly() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18); // a0 > 0 → token0 into pool

        uint256 lpFee      = uint256(10_000e18) * 3000 / 1_000_000;
        uint256 protocol   = lpFee * PhiMath.PROTOCOL_FEE_BPS / 10_000;
        uint256 rewardPart = protocol * hook.REWARD_SHARE_BPS() / 10_000;
        uint256 treasury   = protocol - rewardPart;

        assertEq(hook.accruedFees(poolId), treasury);
        assertEq(_rewardBalance(), rewardPart);
    }

    function test_v2_swap_mints_erc6909() public {
        _add(lp, 1000e18, 3);
        uint256 before = pm.mintCount();
        _swap(10_000e18);
        assertEq(pm.mintCount(), before + 1);
    }

    function test_v2_swap_no_fee_zero_delta() public {
        _add(lp, 1000e18, 3);
        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0
        });
        vm.prank(address(pm));
        hook.afterSwap(address(0), key, sp, BalanceDelta.wrap(0), "");
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── early exit ───────────────────────────────────────────────
    function test_v2_early_exit_fee_on_real_tokens() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        BalanceDelta d = _remove(lp, 1000e18, 500e18);
        assertTrue(d.amount0() < 0);
    }

    function test_v2_early_exit_goes_to_reward_pool() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        _remove(lp, 1000e18, 500e18);
        assertTrue(_rewardBalance() > 0);
    }

    function test_v2_early_exit_mints_erc6909() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 5 days);
        uint256 before = pm.mintCount();
        _remove(lp, 1000e18, 500e18);
        assertTrue(pm.mintCount() > before);
    }

    function test_v2_no_fee_after_gate() public {
        _add(lp, 1000e18, 7);
        vm.warp(block.timestamp + 21 days + 1);
        BalanceDelta d = _remove(lp, 1000e18, 500e18);
        assertEq(d.amount0(), 0);
    }

    // ─── partial exit ─────────────────────────────────────────────
    function test_v2_partial_exit_keeps_shares() public {
        _add(lp, 1000e18, 0);
        vm.warp(block.timestamp + 21 days + 1); // past gate
        _remove(lp, 500e18, 500e18);            // partial exit

        // position still exists with 500e18
        assertEq(hook.getPosition(lp, poolId, TL, TU).liquidity, 500e18);
        // shares updated not deleted
        assertTrue(_totalShares() > 0);
    }

    function test_v2_full_exit_deletes_position() public {
        _add(lp, 1000e18, 0);
        vm.warp(block.timestamp + 3 days + 1);
        _remove(lp, 1000e18, 500e18);
        assertEq(hook.getPosition(lp, poolId, TL, TU).liquidity, 0);
    }

    // ─── rewards ──────────────────────────────────────────────────
    function test_v2_late_joiner_no_historical_rewards() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        _add(lp2, 1000e18, 3);
        assertEq(hook.pendingRewards(lp2, poolId, TL, TU), 0);
        assertTrue(hook.pendingRewards(lp, poolId, TL, TU) > 0);
    }

    function test_v2_exit_harvests_rewards() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        assertTrue(hook.pendingRewards(lp, poolId, TL, TU) > 0);

        vm.warp(block.timestamp + 3 days + 1);
        _remove(lp, 1000e18, 500e18);

        bytes32 posKey = keccak256(abi.encodePacked(lp, poolId, TL, TU));
        (,, uint256 pending) = hook.userRewards(posKey);
        assertTrue(pending > 0);
    }

    // ─── claimRewards ─────────────────────────────────────────────
    function test_v2_claim_zero_reverts() public {
        _add(lp, 1000e18, 3);
        vm.expectRevert(PhiHook.PhiHook__ZeroRewards.selector);
        vm.prank(lp);
        hook.claimRewards(poolId, cur0, TL, TU);
    }

    function test_v2_claim_calls_unlock() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        vm.warp(block.timestamp + 3 days + 1);
        _remove(lp, 1000e18, 500e18);
        vm.prank(lp);
        hook.claimRewards(poolId, cur0, TL, TU);
        assertTrue(pm.unlockCalled());
    }

    function test_v2_claim_correct_recipient() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        vm.warp(block.timestamp + 3 days + 1);
        _remove(lp, 1000e18, 500e18);
        vm.prank(lp);
        hook.claimRewards(poolId, cur0, TL, TU);
        assertEq(pm.lastTakeRecipient(), lp);
    }

    // ─── collectFees ──────────────────────────────────────────────
    function test_v2_collect_fees_zero_reverts() public {
        vm.expectRevert(PhiHook.PhiHook__ZeroFees.selector);
        hook.collectFees(poolId, cur0, address(this));
    }

    function test_v2_collect_fees_only_authorized() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        vm.expectRevert(PhiHook.PhiHook__NotAuthorized.selector);
        vm.prank(address(0xBAD));
        hook.collectFees(poolId, cur0, address(0xBAD));
    }

    function test_v2_collect_fees_clears_balance() public {
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        assertTrue(hook.accruedFees(poolId) > 0);
        hook.collectFees(poolId, cur0, address(this));
        assertEq(hook.accruedFees(poolId), 0);
    }

    function test_v2_approved_collector_can_collect() public {
        hook.setCollector(address(0x123));
        _add(lp, 1000e18, 3);
        _swap(10_000e18);
        vm.prank(address(0x123));
        hook.collectFees(poolId, cur0, address(0x123));
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── setCollector ─────────────────────────────────────────────
    function test_v2_setCollector_only_owner() public {
        vm.expectRevert(PhiHook.PhiHook__NotAuthorized.selector);
        vm.prank(address(0xBAD));
        hook.setCollector(address(0x123));
    }

    function test_v2_setCollector_updates() public {
        hook.setCollector(address(0x123));
        assertEq(hook.approvedCollector(), address(0x123));
    }

    // ─── HOOK_FLAGS ───────────────────────────────────────────────
    function test_v2_hook_flags() public view {
        assertEq(hook.HOOK_FLAGS(), uint160(0x641));
    }

    // ─── REWARD_SHARE_BPS ─────────────────────────────────────────
    function test_v2_reward_share_bps() public view {
        assertEq(hook.REWARD_SHARE_BPS(), 6180);
    }

    // ─── position not found ───────────────────────────────────────
    function test_v2_remove_no_position_reverts() public {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: TL, tickUpper: TU,
            liquidityDelta: -1e18, salt: 0
        });
        vm.expectRevert(PhiHook.PhiHook__PositionNotFound.selector);
        vm.prank(address(pm));
        hook.beforeRemoveLiquidity(address(0xDEAD), key, p, "");
    }

    // ─── proportional distribution ────────────────────────────────
    function test_v2_three_lps_proportional() public {
        _add(lp,  1000e18, 0);
        _add(lp2, 2000e18, 0);
        _add(lp3, 3000e18, 0);
        _swap(100_000e18);

        uint256 pA = hook.pendingRewards(lp,  poolId, TL, TU);
        uint256 pB = hook.pendingRewards(lp2, poolId, TL, TU);
        uint256 pC = hook.pendingRewards(lp3, poolId, TL, TU);

        assertApproxEqAbs(pB, pA * 2, 1e15);
        assertApproxEqAbs(pC, pA * 3, 1e15);
    }
}
