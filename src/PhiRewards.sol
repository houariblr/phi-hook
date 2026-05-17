// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PhiMath} from "./PhiMath.sol";

/// @title  PhiRewards
/// @notice φ-weighted reward distribution for PhiHook LPs
///
/// @dev    ## نموذج التوزيع
///
///         يستخدم نمط rewardPerShare المتراكم (Synthetix-style):
///
///         عند إضافة مكافأة r:
///           rewardPerShare += r / totalShares
///
///         مكافأة LP في أي وقت:
///           pending = shares × (rewardPerShare - rewardDebt)
///
///         shares = liquidity × φ^periods
///           → LP الذي صبر أكثر له shares أكبر
///           → يحصل على نسبة أكبر من نفس المكافأة
///
///         ## مصادر المكافأة
///           1. Early exit fees (من LPs الذين خرجوا مبكراً)
///           2. نسبة من protocol fees (38.2% من swap fees)
///
///         ## ضمانات
///           - لا token تضخيمي
///           - zero external dependencies
///           - كل مكافأة مصدرها ERC-6909 claims حقيقية

library PhiRewards {

    // ─── Structs ──────────────────────────────────────────────────

    struct RewardPool {
        uint256 rewardPerShareX128; // مكافأة لكل share × 2^128 (دقة عالية)
        uint256 totalShares;        // إجمالي الـ φ-weighted shares
        uint256 balance;            // الرصيد الكلي غير الموزَّع
    }

    struct UserReward {
        uint256 shares;          // liquidity × φ^periods
        uint256 rewardDebtX128;  // rewardPerShare عند آخر تحديث × 2^128
        uint256 pending;         // مكافأة جاهزة للسحب
    }

    // ─── Constants ────────────────────────────────────────────────

    uint256 internal constant Q128 = 1 << 128;

    // ─── Core functions ───────────────────────────────────────────

    /// @notice يحسب shares لـ LP بناءً على السيولة وعدد دورات T60
    /// @dev    shares = liquidity × φ^periods / SCALE
    function computeShares(
        uint128 liquidity,
        uint8   periods
    ) internal pure returns (uint256) {
        if (liquidity == 0) return 0;
        uint256 multiplier = PhiMath.phiPow(periods);
        return (uint256(liquidity) * multiplier) / PhiMath.SCALE;
    }

    /// @notice يضيف مكافأة للـ pool ويحدّث rewardPerShare
    /// @param  pool   بيانات الـ reward pool
    /// @param  amount المكافأة المضافة (ERC-6909 claims)
    function addReward(
        RewardPool storage pool,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        pool.balance += amount;

        if (pool.totalShares > 0) {
            // rewardPerShare += amount × Q128 / totalShares
            // نضرب في Q128 للحفاظ على دقة الكسور
            pool.rewardPerShareX128 += (amount * Q128) / pool.totalShares;
        }
        // إذا totalShares = 0: المكافأة تُخزَّن في balance
        // وتُوزَّع عند أول LP يدخل
    }

    /// @notice يسجّل LP جديد أو يحدّث مركزه
    /// @param  pool    بيانات الـ reward pool
    /// @param  user    بيانات المستخدم
    /// @param  liquidity السيولة الجديدة
    /// @param  periods عدد دورات T60
    function registerOrUpdate(
        RewardPool storage pool,
        UserReward storage user,
        uint128 liquidity,
        uint8   periods
    ) internal {
        _harvest(pool, user);

        uint256 newShares = computeShares(liquidity, periods);

        // حدّث totalShares و shares و rewardDebt بناءً على rps الحالي (القديم)
        pool.totalShares    = pool.totalShares - user.shares + newShares;
        user.shares         = newShares;
        user.rewardDebtX128 = (newShares * pool.rewardPerShareX128) / Q128;

        // ─── حل مشكلة الـ rewards المحبوسة ─────────────────────────
        // إذا كان هذا أول LP (totalShares تحوّل من 0 إلى newShares للتو)
        // وهناك balance متراكم عندما لم يكن يوجد LPs، نوزّعه الآن.
        //
        // الترتيب مهم:
        //   1. تمّ ضبط rewardDebt بـ newShares × old_rps / Q128
        //      حيث old_rps = 0 (لأن totalShares كان 0) → rewardDebt = 0
        //   2. الآن نرفع rewardPerShareX128 بالـ balance المحبوس
        //   3. النتيجة: accumulated = newShares × new_rps / Q128 = balance
        //              pending     = balance - rewardDebt(0)    = balance  ✓
        //
        // pool.totalShares == newShares يعني: هذا أول LP في الـ pool
        // (أو عاد totalShares إلى 0 وهذا أول LP جديد بعد خروج الجميع)
        if (pool.totalShares == newShares && pool.balance > 0) {
            pool.rewardPerShareX128 += (pool.balance * Q128) / newShares;
        }
    }

    /// @notice يحذف LP من الـ pool ويجمع مكافآته
    /// @return harvested المكافآت المجمّعة
    function exit(
        RewardPool storage pool,
        UserReward storage user
    ) internal returns (uint256 harvested) {
        _harvest(pool, user);
        harvested = user.pending;
        user.pending = 0;

        // إزالة الـ shares
        if (pool.totalShares >= user.shares) {
            pool.totalShares -= user.shares;
        } else {
            pool.totalShares = 0;
        }
        user.shares         = 0;
        user.rewardDebtX128 = 0;
    }

    /// @notice يحسب المكافأة المعلّقة لـ LP (view)
    function pendingReward(
        RewardPool storage pool,
        UserReward storage user
    ) internal view returns (uint256) {
        if (user.shares == 0) return user.pending;

        uint256 accumulated = (user.shares * pool.rewardPerShareX128) / Q128;
        uint256 debt        = user.rewardDebtX128;

        uint256 newReward = accumulated > debt ? accumulated - debt : 0;
        return user.pending + newReward;
    }

    // ─── Public harvest (للاستدعاء من PhiHookV2 مباشرة) ──────────

    /// @notice يجمع المكافآت المستحقة لـ user ويضيفها لـ user.pending
    /// @dev    نفس منطق _harvest لكن public — يتيح للـ hook استدعاءها
    ///         مباشرة بدون تكرار الحسابات.
    function harvest(
        RewardPool storage pool,
        UserReward storage user
    ) internal {
        _harvest(pool, user);
    }

    // ─── Internal ─────────────────────────────────────────────────

    function _harvest(
        RewardPool storage pool,
        UserReward storage user
    ) internal {
        if (user.shares == 0) return;

        uint256 accumulated = (user.shares * pool.rewardPerShareX128) / Q128;
        uint256 debt        = user.rewardDebtX128;

        if (accumulated > debt) {
            uint256 newReward = accumulated - debt;
            user.pending     += newReward;
            pool.balance      = pool.balance > newReward
                ? pool.balance - newReward : 0;
        }

        // تحديث debt
        user.rewardDebtX128 = accumulated;
    }
}
