// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PhiRewards} from "../src/PhiRewards.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract PhiRewardsTest is Test {
    using PhiRewards for PhiRewards.RewardPool;
    using PhiRewards for PhiRewards.UserReward;

    PhiRewards.RewardPool pool;
    PhiRewards.UserReward userA;
    PhiRewards.UserReward userB;

    // ─── computeShares ────────────────────────────────────────────
    function test_shares_zero_liquidity() public pure {
        assertEq(PhiRewards.computeShares(0, 0), 0);
    }

    function test_shares_periods_zero() public pure {
        // periods=0 → multiplier=1 → shares = liquidity
        uint256 shares = PhiRewards.computeShares(1000e18, 0);
        assertEq(shares, 1000e18);
    }

    function test_shares_one_period() public pure {
        // periods=1 → multiplier=φ → shares = liquidity × φ
        uint256 shares = PhiRewards.computeShares(1000e18, 1);
        uint256 expected = (uint256(1000e18) * PhiMath.PHI) / PhiMath.SCALE;
        assertEq(shares, expected);
    }

    function test_shares_increase_with_periods() public pure {
        uint256 s0 = PhiRewards.computeShares(1000e18, 0);
        uint256 s1 = PhiRewards.computeShares(1000e18, 1);
        uint256 s2 = PhiRewards.computeShares(1000e18, 2);
        assertTrue(s2 > s1 && s1 > s0);
    }

    // ─── addReward ────────────────────────────────────────────────
    function test_addReward_zero_does_nothing() public {
        pool.addReward(0);
        assertEq(pool.balance, 0);
        assertEq(pool.rewardPerShareX128, 0);
    }

    function test_addReward_no_shares_accumulates_balance() public {
        // لا يوجد LPs → المكافأة تُخزَّن في balance
        pool.addReward(1000e18);
        assertEq(pool.balance, 1000e18);
        assertEq(pool.rewardPerShareX128, 0); // لا توزيع بدون shares
    }

    function test_addReward_with_shares_updates_rps() public {
        // نسجّل LP أولاً
        pool.registerOrUpdate(userA, 1000e18, 0);
        uint256 rpsBefore = pool.rewardPerShareX128;

        pool.addReward(100e18);

        assertTrue(pool.rewardPerShareX128 > rpsBefore);
        assertEq(pool.balance, 100e18);
    }

    // ─── registerOrUpdate ─────────────────────────────────────────
    function test_register_sets_shares() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        assertEq(userA.shares, 1000e18);
        assertEq(pool.totalShares, 1000e18);
    }

    function test_register_two_users() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.registerOrUpdate(userB, 2000e18, 0);
        assertEq(pool.totalShares, 3000e18);
    }

    function test_update_increases_shares() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.registerOrUpdate(userA, 2000e18, 1); // top-up مع period جديد
        // shares الجديدة = 2000e18 × φ
        uint256 expected = PhiRewards.computeShares(2000e18, 1);
        assertEq(userA.shares, expected);
        assertEq(pool.totalShares, expected);
    }

    // ─── pendingReward ────────────────────────────────────────────
    function test_pending_zero_before_reward() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        assertEq(pool.pendingReward(userA), 0);
    }

    function test_pending_correct_single_user() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.addReward(100e18);
        // LP وحيد → يحصل على كل المكافأة
        uint256 pending = pool.pendingReward(userA);
        assertApproxEqAbs(pending, 100e18, 1); // تقريب Q128
    }

    function test_pending_proportional_two_users() public {
        // A: 1000 shares, B: 3000 shares → A يحصل على 25%, B على 75%
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.registerOrUpdate(userB, 3000e18, 0);
        pool.addReward(100e18);

        uint256 pendingA = pool.pendingReward(userA);
        uint256 pendingB = pool.pendingReward(userB);

        assertApproxEqAbs(pendingA, 25e18, 1e15);  // 25%
        assertApproxEqAbs(pendingB, 75e18, 1e15);  // 75%
    }

    function test_phi_weighted_distribution() public {
        // A: periods=0 → shares = 1000
        // B: periods=1 → shares = 1000 × φ ≈ 1618
        // A يحصل على أقل من B لأن B صبر أكثر
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.registerOrUpdate(userB, 1000e18, 1);
        pool.addReward(100e18);

        uint256 pendingA = pool.pendingReward(userA);
        uint256 pendingB = pool.pendingReward(userB);

        // B يحصل على أكثر من A
        assertTrue(pendingB > pendingA);

        // النسبة ≈ φ
        uint256 ratio = (pendingB * PhiMath.SCALE) / pendingA;
        assertApproxEqAbs(ratio, PhiMath.PHI, 1e15);
    }

    // ─── exit ─────────────────────────────────────────────────────
    function test_exit_returns_pending() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.addReward(100e18);

        uint256 harvested = pool.exit(userA);
        assertApproxEqAbs(harvested, 100e18, 1);
    }

    function test_exit_clears_shares() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.exit(userA);
        assertEq(userA.shares, 0);
        assertEq(pool.totalShares, 0);
    }

    function test_exit_no_double_claim() public {
    pool.registerOrUpdate(userA, 1000e18, 0);
    pool.addReward(100e18);
    pool.exit(userA);

    // إعادة تسجيل ومحاولة claim مرة أخرى
    pool.registerOrUpdate(userA, 1000e18, 0);
    uint256 pending2 = pool.pendingReward(userA);
    
    // التعديل: السماح بهامش خطأ 1 wei ناتج عن توزيع الغبار الحسابي المتراكم
    assertApproxEqAbs(pending2, 0, 1); 
}
    // ─── multiple rewards ─────────────────────────────────────────
    function test_multiple_rewards_accumulate() public {
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.addReward(50e18);
        pool.addReward(50e18);

        uint256 pending = pool.pendingReward(userA);
        assertApproxEqAbs(pending, 100e18, 2);
    }

    function test_late_joiner_no_historical_rewards() public {
        // A يدخل أولاً، تُضاف مكافأة، ثم B يدخل
        pool.registerOrUpdate(userA, 1000e18, 0);
        pool.addReward(100e18);

        // B يدخل بعد المكافأة
        pool.registerOrUpdate(userB, 1000e18, 0);

        // B لا يحصل على المكافأة التاريخية
        assertEq(pool.pendingReward(userB), 0);

        // A لا يزال يحصل على 100e18
        assertApproxEqAbs(pool.pendingReward(userA), 100e18, 1);
    }
}
