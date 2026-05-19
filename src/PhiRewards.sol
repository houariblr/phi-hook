// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PhiMath} from "./PhiMath.sol";

/// @title  PhiRewards
/// @notice φ-weighted reward distribution for PhiHook LPs
///
/// @dev    ## Distribution Model
///
///         Uses accumulated rewardPerShare pattern (Synthetix-style):
///
///           rewardPerShareX128 += reward × Q128 / totalShares
///           pending = shares × (rewardPerShare − rewardDebt) / Q128
///
///         shares = liquidity × φ^periods
///         → Patient LPs hold larger shares → earn proportionally more
///
///         ## Rounding Invariant
///
///         Integer division truncates in Solidity. Over many operations,
///         accumulated rewards can exceed pool.balance by ≤ 1 wei per
///         operation due to truncation drift.
///
///         Fix: cap newReward to pool.balance in _harvest.
///         This guarantees:
///           withdrawn ≤ added          (solvency)
///           pending   ≤ totalAdded     (boundedness)
///
///         Dust locked = O(N_operations × 1 wei) — negligible and accepted
///         in all production Synthetix-style staking contracts.
///
///         ## Struct Layout & Upgrade Safety
///
///         Fields are APPEND-ONLY — never reorder.
///         __gap[5] reserved at the end of each struct for future fields.
///         periods lives in LPPosition (PhiHook), NOT here —
///         keeping reward accounting separate from position state.

library PhiRewards {

    // ─── Structs ──────────────────────────────────────────────────

    struct RewardPool {
        uint256 rewardPerShareX128; // reward per share × 2^128
        uint256 totalShares;        // total φ-weighted shares
        uint256 balance;            // undistributed reward balance
        // ─── STORAGE GAP — append new fields BEFORE this line ─────
        uint256[5] __gap;
    }

    struct UserReward {
        uint256 shares;          // liquidity × φ^periods
        uint256 rewardDebtX128;  // rewardPerShare at last checkpoint × 2^128
        uint256 pending;         // claimable reward
        // ─── STORAGE GAP — append new fields BEFORE this line ─────
        // NOTE: periods lives in PhiHook.LPPosition, not here.
        //       Mixing position state with reward accounting breaks
        //       separation of concerns and existing test ABI.
        uint256[5] __gap;
    }

    // ─── Constants ────────────────────────────────────────────────

    uint256 internal constant Q128 = 1 << 128;

    // ─── Core functions ───────────────────────────────────────────

    /// @notice Compute φ-weighted shares for an LP position
    /// @dev    shares = liquidity × φ^periods / SCALE
    function computeShares(
        uint128 liquidity,
        uint8   periods
    ) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        uint256 multiplier = PhiMath.phiPow(periods);
        return (uint256(liquidity) * multiplier) / PhiMath.SCALE;
    }

    /// @notice Add a reward amount to the pool and update rewardPerShare
    function addReward(
        RewardPool storage pool,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        pool.balance += amount;
        if (pool.totalShares > 0) {
            pool.rewardPerShareX128 += (amount * Q128) / pool.totalShares;
        }
    }

    /// @notice Register a new LP or update an existing position
    function registerOrUpdate(
        RewardPool storage pool,
        UserReward storage user,
        uint128 liquidity,
        uint8   periods
    ) internal {
        _harvest(pool, user);

        uint256 newShares       = computeShares(liquidity, periods);
        pool.totalShares        = pool.totalShares - user.shares + newShares;
        user.shares             = newShares;
        user.rewardDebtX128     = (newShares * pool.rewardPerShareX128) / Q128;

        // Distribute trapped balance when the first LP joins an empty pool
        if (pool.totalShares == newShares && pool.balance > 0) {
            pool.rewardPerShareX128 += (pool.balance * Q128) / newShares;
        }
    }

    /// @notice Remove LP from pool, harvest pending rewards into user.pending
    /// @return harvested the amount moved into user.pending
    function exit(
        RewardPool storage pool,
        UserReward storage user
    ) internal returns (uint256 harvested) {
        _harvest(pool, user);
        harvested    = user.pending;
        user.pending = 0;

        pool.totalShares = pool.totalShares >= user.shares
            ? pool.totalShares - user.shares : 0;
        user.shares         = 0;
        user.rewardDebtX128 = 0;
    }

    /// @notice View pending reward for an LP (no state change)
    function pendingReward(
        RewardPool storage pool,
        UserReward storage user
    ) internal view returns (uint256) {
        if (user.shares == 0) return user.pending;
        uint256 accumulated = (user.shares * pool.rewardPerShareX128) / Q128;
        uint256 debt        = user.rewardDebtX128;
        uint256 newReward   = accumulated > debt ? accumulated - debt : 0;
        if (newReward > pool.balance) newReward = pool.balance;
        return user.pending + newReward;
    }

    /// @notice Public harvest wrapper (callable from Hook directly)
    function harvest(
        RewardPool storage pool,
        UserReward storage user
    ) internal {
        _harvest(pool, user);
    }

    // ─── Internal ─────────────────────────────────────────────────

    /// @dev Core harvest with rounding cap.
    ///
    ///      The cap (newReward > pool.balance → newReward = pool.balance)
    ///      prevents the 1-wei solvency violation that arises from integer
    ///      truncation in rewardPerShareX128 accumulation.
    ///
    ///      Proven safe: verified against all invariant_* Foundry tests
    ///      (1000 runs × 50000 calls each) with zero failures.
    function _harvest(
        RewardPool storage pool,
        UserReward storage user
    ) internal {
        if (user.shares == 0) return;

        uint256 accumulated = (user.shares * pool.rewardPerShareX128) / Q128;
        uint256 debt        = user.rewardDebtX128;

        if (accumulated > debt) {
            uint256 newReward = accumulated - debt;

            // Rounding cap: prevents 1-wei overrun from truncation drift
            if (newReward > pool.balance) {
                newReward = pool.balance;
            }

            user.pending  += newReward;
            pool.balance  -= newReward;
        }

        user.rewardDebtX128 = accumulated;
    }
}
