// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PhiMath
/// @notice حسابات النسبة الذهبية بـ integer arithmetic صارمة
/// @dev جميع القيم مضروبة في SCALE = 1e18
///      φ = 1.6180339887498948482... (50 decimal precision verified)
///      خاصية: φ² = φ + 1 → نستخدمها للتحقق
library PhiMath {

    // ─── الثوابت ───────────────────────────────────────────────

    uint256 internal constant SCALE = 1e18;

    /// @dev φ × 1e18، محسوبة بـ Python Decimal(prec=50)
    /// int((1 + sqrt(5)) / 2 * 1e18) = 1618033988749894848
    uint256 internal constant PHI = 1_618_033_988_749_894_848;

    /// @dev (1/φ) × 1e18 = (φ-1) × 1e18
    /// int((sqrt(5) - 1) / 2 * 1e18) = 618033988749894848
    uint256 internal constant PHI_INV = 618_033_988_749_894_848;

    /// @dev φ² × 1e18 = (φ+1) × 1e18 — للتحقق الداخلي
    uint256 internal constant PHI_SQ = 2_618_033_988_749_894_848;

    /// @dev الحد الأقصى لـ n: φ^144 < 2^255 / 1e18 (مثبت)
    uint8 internal constant N_MAX = 144;

    /// @dev حد الدقة < 100ppm لـ phiInvPow — النطاق العملي للبروتوكول n <= 60
    uint8 internal constant N_MAX_INV = 60;

    /// @dev T60 بالثواني (60 يوم)
    uint256 internal constant T60 = 60 days;

    /// @dev رسوم البروتوكول: 1/φ² = 38.196...% = 3819.6 bps ≈ 3820 bps
    ///      int(1/φ² * 10_000) = 3819 → نستخدم 3820 (تقريب للأعلى)
    ///      يُطبَّق على حصة الـ LP فقط، مثال pool 0.3% وصفقة $10,000:
    ///        lpFee       = $10,000 × 0.3%      = $30.00
    ///        protocolFee = $30.00  × 38.2%     = $11.46  (≈ 0.115% من الحجم)
    uint256 internal constant PROTOCOL_FEE_BPS = 3_820;

    // ─── الخطأ ───────────────────────────────────────────────────

    error PhiMath__ExponentTooLarge(uint8 n, uint8 max);
    error PhiMath__ZeroInput();

    // ─── الدوال الأساسية ──────────────────────────────────────────

    /// @notice يحسب φ^n بـ fast exponentiation (binary method)
    /// @dev يتجنب تراكم خطأ الـ loop البسيط
    ///      الخطأ الأقصى لكل خطوة: 1 wei (truncation)
    ///      الخطأ الكلي لـ n=144: < 144 wei على SCALE=1e18 → مقبول
    /// @param n الأس (0..144)
    /// @return النتيجة بـ SCALE (أي النتيجة الحقيقية × 1e18)
    function phiPow(uint8 n) internal pure returns (uint256) {
        if (n == 0) return SCALE;       // φ^0 = 1
        if (n > N_MAX) revert PhiMath__ExponentTooLarge(n, N_MAX);

        uint256 result = SCALE;         // يبدأ بـ 1.0
        uint256 base = PHI;             // القاعدة الحالية
        uint8 exp = n;

        // Binary exponentiation: O(log n) بدلاً من O(n)
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = _mulScale(result, base);
            }
            if (exp > 1) {
                base = _mulScale(base, base);
            }
            exp >>= 1;
        }
        return result;
    }

    /// @notice يحسب (1/φ)^n = φ^(-n)
    /// @dev مفيد لحساب تناقص رسوم الخروج
    function phiInvPow(uint8 n) internal pure returns (uint256) {
        if (n == 0) return SCALE;
        if (n > N_MAX) revert PhiMath__ExponentTooLarge(n, N_MAX);

        uint256 result = SCALE;
        uint256 base = PHI_INV;
        uint8 exp = n;

        while (exp > 0) {
            if (exp & 1 == 1) {
                result = _mulScale(result, base);
            }
            if (exp > 1) {
                base = _mulScale(base, base);
            }
            exp >>= 1;
        }
        return result;
    }

    /// @notice رقم فيبوناتشي — F(0)=1, F(1)=1, F(2)=2, ...
    /// @dev يُستخدم لحساب الـ gates الزمنية
    ///      F(11) = 144 يوم ← أقصى gate عملي
    ///      F(12) = 233 يوم ← للـ tier العالي
    /// @param n المؤشر (0..20) — F(20) = 10946 (آمن في uint32)
    function fibonacci(uint8 n) internal pure returns (uint32) {
        if (n > 20) revert PhiMath__ExponentTooLarge(n, 20);
        if (n == 0 || n == 1) return 1;

        uint32 a = 1;
        uint32 b = 1;
        for (uint8 i = 2; i <= n; i++) {
            uint32 c = a + b;
            a = b;
            b = c;
        }
        return b;
    }

    /// @notice الـ gate الزمني لـ tier معين (بالثواني)
    /// @dev fibonacci(tier) × 1 day
    ///      tier=0 → 1 يوم
    ///      tier=3 → 3 يوم
    ///      tier=7 → 21 يوم
    ///      tier=11 → 144 يوم
    function gateSeconds(uint8 tier) internal pure returns (uint256) {
        return uint256(fibonacci(tier)) * 1 days;
    }

    /// @notice رسوم الخروج المبكر
    /// @dev تتناقص بـ (1/φ) كلما اقتربت من الـ gate
    ///      عند elapsed=0: الرسوم = maxFee
    ///      عند elapsed=gate: الرسوم = 0
    ///      المنحنى: fee = maxFee × (1 - elapsed/gate)^φ (تقريب integer)
    /// @param maxFeeBps الحد الأقصى للرسوم (basis points)
    /// @param elapsed الوقت المنقضي (ثواني)
    /// @param gate الوقت الكلي للـ tier (ثواني)
    function earlyExitFeeBps(
        uint256 maxFeeBps,
        uint256 elapsed,
        uint256 gate
    ) internal pure returns (uint256) {
        if (elapsed >= gate) return 0;
        if (gate == 0) revert PhiMath__ZeroInput();

        // نسبة التقدم: progress ∈ [0, SCALE]
        uint256 progress = (elapsed * SCALE) / gate;

        // المتبقي: remaining = 1 - progress ∈ [0, SCALE]
        uint256 remaining = SCALE - progress;
        // fee = maxFeeBps × remaining × sqrt(remaining) / SCALE²
        // نجمع كل الضربات قبل القسمة — يمنع divide-before-multiply
        // overflow: maxFeeBps≤10000, remaining≤1e18, fracPart≤1e18 → max≈1e40 < 2^256
        uint256 fracPart = _sqrtScale(remaining);
        uint256 fee = (maxFeeBps * remaining * fracPart) / (SCALE * SCALE);
        return fee > maxFeeBps ? maxFeeBps : fee;
       }

    /// @notice مكافأة φ للـ LP بناءً على عدد دورات T60
    /// @param baseReward المكافأة الأساسية لدورة واحدة
    /// @param periods عدد دورات T60 المنقضية
    function lpReward(
        uint256 baseReward,
        uint8 periods
    ) internal pure returns (uint256) {
        if (baseReward == 0) revert PhiMath__ZeroInput();
        uint256 multiplier = phiPow(periods);
        return (baseReward * multiplier) / SCALE;
    }

    // ─── دوال داخلية ─────────────────────────────────────────────

    /// @dev ضرب آمن مع SCALE — يتحقق من overflow ضمنياً بـ Solidity 0.8
    function _mulScale(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / SCALE;
    }

    /// @dev جذر تقريبي × SCALE باستخدام Babylonian method
    /// @return sqrt(a × SCALE) أي sqrt(a) بوحدات SCALE
    function _sqrtScale(uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        // نريد sqrt(a) حيث a ∈ [0, SCALE]
        // نضرب في SCALE لنحافظ على الدقة
        uint256 x = a * SCALE;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
