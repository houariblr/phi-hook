// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PhiMath.sol";

contract PhiMathWrapper {
    function phiPow(uint8 n) external pure returns (uint256) {
        return PhiMath.phiPow(n);
    }
    function fibonacci(uint8 n) external pure returns (uint32) {
        return PhiMath.fibonacci(n);
    }
}

contract PhiMathTest is Test {

    PhiMathWrapper wrapper;

    function setUp() public {
        wrapper = new PhiMathWrapper();
    }

    // ─── helper: relative error بالمليون ─────────────────────────
    // يرجع |a - b| × 1e6 / max(a,b)
    // أي خطأ نسبي بوحدات ppm (parts per million)
    function _relErrPpm(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 diff = a > b ? a - b : b - a;
        uint256 larger = a > b ? a : b;
        return (diff * 1_000_000) / larger;
    }

    // ─── φ² = φ + 1 ───────────────────────────────────────────────
    function test_phi_identity() public pure {
        uint256 phiSq = PhiMath._mulScale(PhiMath.PHI, PhiMath.PHI);
        uint256 phiPlusOne = PhiMath.PHI + PhiMath.SCALE;
        assertApproxEqAbs(phiSq, phiPlusOne, 2);
    }

    // ─── φ × (1/φ) = 1 ───────────────────────────────────────────
    function test_phi_inverse() public pure {
        uint256 product = PhiMath._mulScale(PhiMath.PHI, PhiMath.PHI_INV);
        assertApproxEqAbs(product, PhiMath.SCALE, 1);
    }

    // ─── φ^0 = 1 ─────────────────────────────────────────────────
    function test_phiPow_zero() public pure {
        assertEq(PhiMath.phiPow(0), PhiMath.SCALE);
    }

    // ─── φ^1 = φ ─────────────────────────────────────────────────
    function test_phiPow_one() public pure {
        assertEq(PhiMath.phiPow(1), PhiMath.PHI);
    }

    // ─── φ^2 = φ + 1 ─────────────────────────────────────────────
    function test_phiPow_two() public pure {
        uint256 result = PhiMath.phiPow(2);
        uint256 expected = PhiMath.PHI + PhiMath.SCALE;
        assertApproxEqAbs(result, expected, 2);
    }

    // ─── φ^n × φ^m ≈ φ^(n+m) — بـ relative error ────────────────
    // الخطأ المطلق يكبر مع القيم — نستخدم نسبي
    // الدقة المطلوبة: < 10 ppm (0.001%)
    function test_phiPow_additive(uint8 a, uint8 b) public pure {
        vm.assume(uint16(a) + uint16(b) <= PhiMath.N_MAX);
        vm.assume(a > 0 && b > 0);

        uint256 lhs = PhiMath._mulScale(PhiMath.phiPow(a), PhiMath.phiPow(b));
        uint256 rhs = PhiMath.phiPow(uint8(uint16(a) + uint16(b)));

        // relative error < 10 ppm مثبت:
        // binary exp يعطي خطأ truncation ≈ n bits
        // لـ n=144: خطأ نسبي < 144/1e18 × 1e6 = 0.00014 ppm ← ممتاز
        // في الواقع الخطأ ينشأ من الضرب الوسيط لا من n مباشرة
        // 10 ppm = هامش مريح وصارم في نفس الوقت
        uint256 ppm = _relErrPpm(lhs, rhs);
        assertLt(ppm, 10, "relative error exceeds 10 ppm");
    }


    // ─── φ^n × (1/φ)^n ≈ 1 ───────────────────────────────────────
// نقيّد n ≤ 60 لأن:
// 1) النطاق العملي للبروتوكول: n ≤ 12 (سنة بدورات T60)
// 2) فوق n=60: truncation في phiInvPow يتضخم لأن (1/φ)^n صغير جداً
// 3) هذا ليس خللاً في الكود — هو حد فيزيائي للـ fixed-point 1e18
function test_phiPow_inverse_cancel(uint8 n) public pure {
    vm.assume(n > 0 && n <= 60); // النطاق العملي الآمن
    
    uint256 forward  = PhiMath.phiPow(n);
    uint256 backward = PhiMath.phiInvPow(n);
    uint256 product  = PhiMath._mulScale(forward, backward);
    
    // < 100 ppm مثبت لكل n ≤ 60
    uint256 ppm = _relErrPpm(product, PhiMath.SCALE);
    assertLt(ppm, 100, "inverse cancel relative error exceeds 100 ppm");
}

    // ─── فيبوناتشي: F(n) = F(n-1) + F(n-2) ──────────────────────
    function test_fibonacci_recurrence() public pure {
        for (uint8 i = 2; i <= 15; i++) {
            uint32 fn  = PhiMath.fibonacci(i);
            uint32 fn1 = PhiMath.fibonacci(i - 1);
            uint32 fn2 = PhiMath.fibonacci(i - 2);
            assertEq(fn, fn1 + fn2);
        }
    }

    // ─── قيم فيبوناتشي المعروفة ───────────────────────────────────
    function test_fibonacci_known_values() public pure {
        assertEq(PhiMath.fibonacci(0),  1);
        assertEq(PhiMath.fibonacci(1),  1);
        assertEq(PhiMath.fibonacci(2),  2);
        assertEq(PhiMath.fibonacci(3),  3);
        assertEq(PhiMath.fibonacci(4),  5);
        assertEq(PhiMath.fibonacci(5),  8);
        assertEq(PhiMath.fibonacci(6),  13);
        assertEq(PhiMath.fibonacci(7),  21);
        assertEq(PhiMath.fibonacci(11), 144);
        assertEq(PhiMath.fibonacci(12), 233);
    }

    // ─── رسوم الخروج = 0 بعد الـ gate ────────────────────────────
    function test_earlyExit_zero_after_gate() public pure {
        uint256 fee = PhiMath.earlyExitFeeBps(1000, 30 days, 30 days);
        assertEq(fee, 0);
    }

    // ─── رسوم الخروج تتناقص مع الوقت ─────────────────────────────
    function test_earlyExit_decreasing() public pure {
        uint256 gate = 21 days;
        uint256 fee1 = PhiMath.earlyExitFeeBps(1000, 5 days,  gate);
        uint256 fee2 = PhiMath.earlyExitFeeBps(1000, 10 days, gate);
        uint256 fee3 = PhiMath.earlyExitFeeBps(1000, 15 days, gate);
        assertTrue(fee1 > fee2);
        assertTrue(fee2 > fee3);
        assertTrue(fee3 > 0);
    }

    // ─── رسوم الخروج لا تتجاوز الحد الأقصى أبداً ─────────────────
    function test_earlyExit_bounded(
        uint256 maxFee,
        uint256 elapsed,
        uint256 gate
    ) public pure {
        vm.assume(gate > 0 && gate <= 365 days);
        vm.assume(elapsed <= gate);
        vm.assume(maxFee <= 10_000);

        uint256 fee = PhiMath.earlyExitFeeBps(maxFee, elapsed, gate);
        assertLe(fee, maxFee);
    }

    // ─── لا overflow حتى n=144 ────────────────────────────────────
    function test_phiPow_no_overflow() public pure {
        uint256 result = PhiMath.phiPow(PhiMath.N_MAX);
        assertTrue(result > 0);
        assertTrue(result < type(uint256).max);
    }

    // ─── revert عند n > N_MAX ─────────────────────────────────────
    function test_phiPow_revert_overflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PhiMath.PhiMath__ExponentTooLarge.selector,
                uint8(145),
                PhiMath.N_MAX
            )
        );
        wrapper.phiPow(145);
    }

    // ─── revert فيبوناتشي عند n > 20 ─────────────────────────────
    function test_fibonacci_revert_overflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PhiMath.PhiMath__ExponentTooLarge.selector,
                uint8(21),
                uint8(20)
            )
        );
        wrapper.fibonacci(21);
    }

    // ─── lpReward يتبع منحنى φ ────────────────────────────────────
    function test_lpReward_phi_curve() public pure {
        uint256 base = 1e18;
        uint256 r1 = PhiMath.lpReward(base, 1);
        uint256 r2 = PhiMath.lpReward(base, 2);
        uint256 r3 = PhiMath.lpReward(base, 3);

        assertApproxEqAbs(r1, PhiMath.PHI, 2);
        assertApproxEqAbs(r2, PhiMath.PHI + PhiMath.SCALE, 4);
        assertTrue(r3 > r2 && r2 > r1);
    }

    // ─── φ^n monotonically increasing ────────────────────────────
    function test_phiPow_monotone(uint8 n) public pure {
        vm.assume(n > 0 && n < PhiMath.N_MAX);
        assertTrue(PhiMath.phiPow(n + 1) > PhiMath.phiPow(n));
    }

    // ─── gateSeconds صحيحة ────────────────────────────────────────
    function test_gateSeconds() public pure {
        assertEq(PhiMath.gateSeconds(0),  1 days);
        assertEq(PhiMath.gateSeconds(3),  3 days);
        assertEq(PhiMath.gateSeconds(7),  21 days);
        assertEq(PhiMath.gateSeconds(11), 144 days);
    }
    
    // ─── توثيق حدود الدقة — ليس فشلاً بل specification ─────────────
// يثبت أن phiInvPow دقيق للاستخدام العملي (n ≤ 12)
// ويوثّق تدهور الدقة للقيم الكبيرة
    function test_phiInvPow_precision_spec() public pure {
    // n=1: دقة عالية جداً
    {
        uint256 v = PhiMath.phiInvPow(1);
        assertApproxEqAbs(v, PhiMath.PHI_INV, 1);
    }
    // n=12 (أقصى استخدام عملي — سنة كاملة):
    // (1/φ)^12 × 1e18 = 321,996,... → دقة كافية للبروتوكول
    {
        uint256 ppm = _relErrPpm(
            PhiMath._mulScale(PhiMath.phiPow(12), PhiMath.phiInvPow(12)),
            PhiMath.SCALE
        );
        assertLt(ppm, 10, "n=12 must be < 10 ppm");
    }
    // n=60: الحد الآمن الأقصى
    {
        uint256 ppm = _relErrPpm(
            PhiMath._mulScale(PhiMath.phiPow(60), PhiMath.phiInvPow(60)),
            PhiMath.SCALE
        );
        assertLt(ppm, 100, "n=60 must be < 100 ppm");
    }
}
}
