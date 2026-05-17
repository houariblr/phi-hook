// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "../lib/v4-core/src/types/PoolOperation.sol";
import {PhiHook} from "../src/PhiHook.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract MockPMFull {
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;
    bool    public unlockCalled;
    // burn tracking
    uint256 public lastBurnAmount;

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCalled = true;
        return IUnlockCB(msg.sender).unlockCallback(data);
    }
    function take(Currency, address to, uint256 amount) external {
        lastTakeRecipient = to;
        lastTakeAmount    = amount;
    }
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256 amount) external {
        lastBurnAmount = amount;
    }
}

interface IUnlockCB {
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

contract FeeCollectorTest is Test {
    PhiHook      hook;
    FeeCollector collector;
    MockPMFull   mockManager;

    address lp        = address(0xBEEF);
    address lp2       = address(0xCAFE);
    address recipient = address(0xABCD);

    PoolKey key;
    bytes32 poolId;
    Currency currency0;

    function setUp() public {
        mockManager = new MockPMFull();
        hook        = new PhiHook(IPoolManager(address(mockManager)));
        // FeeCollector constructor يأخذ PhiHook فقط
        collector   = new FeeCollector(hook);
        // نفوّض collector
        hook.setCollector(address(collector));

        currency0 = Currency.wrap(address(0x1));
        key = PoolKey({
            currency0:   currency0,
            currency1:   Currency.wrap(address(0x2)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       hook
        });
        poolId = keccak256(abi.encode(key));
    }

    // helper: يضيف سيولة ويخرج مبكراً لتوليد رسوم
    function _generateFees() internal returns (uint256) {
        ModifyLiquidityParams memory p = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60,
            liquidityDelta: int256(uint256(1000e18)),
            salt: 0
        });
        vm.prank(address(mockManager));
        hook.afterAddLiquidity(lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0),
            abi.encodePacked(uint8(7))
        );

        vm.warp(block.timestamp + 5 days);

        // delta.amount0() = 500e18 (LP يسترد tokens)
        // fee = 500e18 × feeBps / 10_000
        BalanceDelta lpDelta = BalanceDelta.wrap(
            (int256(500e18) << 128) | int256(0)
        );

        ModifyLiquidityParams memory p2 = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60,
            liquidityDelta: -int256(uint256(1000e18)),
            salt: 0
        });
        vm.prank(address(mockManager));
        hook.beforeRemoveLiquidity(lp, key, p2, "");
        vm.prank(address(mockManager));
        hook.afterRemoveLiquidity(lp, key, p2, lpDelta, BalanceDelta.wrap(0), "");

        return hook.accruedFees(poolId);
    }

    // ─── constructor ──────────────────────────────────────────────
    function test_constructor_sets_hook() public view {
        assertEq(address(collector.hook()), address(hook));
    }

    function test_constructor_sets_owner() public view {
        assertEq(collector.owner(), address(this));
    }

    function test_constructor_zero_hook_reverts() public {
        vm.expectRevert(FeeCollector.FeeCollector__ZeroAddress.selector);
        new FeeCollector(PhiHook(address(0)));
    }

    // ─── collect — access control ─────────────────────────────────
    function test_collect_only_owner() public {
        _generateFees();
        vm.expectRevert(FeeCollector.FeeCollector__NotOwner.selector);
        vm.prank(address(0xBAD));
        collector.collect(poolId, currency0, recipient);
    }

    function test_collect_zero_recipient_reverts() public {
        _generateFees();
        vm.expectRevert(FeeCollector.FeeCollector__ZeroAddress.selector);
        collector.collect(poolId, currency0, address(0));
    }

    // ─── collect — success ────────────────────────────────────────
    function test_collect_calls_unlock() public {
        _generateFees();
        collector.collect(poolId, currency0, recipient);
        assertTrue(mockManager.unlockCalled());
    }

    function test_collect_take_correct_recipient() public {
        _generateFees();
        collector.collect(poolId, currency0, recipient);
        assertEq(mockManager.lastTakeRecipient(), recipient);
    }

    function test_collect_take_correct_amount() public {
        uint256 fees = _generateFees();
        collector.collect(poolId, currency0, recipient);
        assertEq(mockManager.lastTakeAmount(), fees);
    }

    function test_collect_clears_hook_fees() public {
        _generateFees();
        collector.collect(poolId, currency0, recipient);
        assertEq(hook.accruedFees(poolId), 0);
    }

    function test_collect_zero_fees_reverts() public {
        // لا رسوم → hook.collectFees ترجع PhiHook__ZeroFees
        vm.expectRevert(PhiHook.PhiHook__ZeroFees.selector);
        collector.collect(poolId, currency0, recipient);
    }

    // ─── collectBatch ─────────────────────────────────────────────
    function test_collectBatch_only_owner() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = poolId;
        Currency[] memory curs = new Currency[](1);
        curs[0] = currency0;

        vm.expectRevert(FeeCollector.FeeCollector__NotOwner.selector);
        vm.prank(address(0xBAD));
        collector.collectBatch(ids, curs, recipient);
    }

    function test_collectBatch_length_mismatch_reverts() public {
        bytes32[] memory ids = new bytes32[](2);
        Currency[] memory curs = new Currency[](1);
        vm.expectRevert(FeeCollector.FeeCollector__LengthMismatch.selector);
        collector.collectBatch(ids, curs, recipient);
    }

    function test_collectBatch_single_pool() public {
        _generateFees();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = poolId;
        Currency[] memory curs = new Currency[](1);
        curs[0] = currency0;

        collector.collectBatch(ids, curs, recipient);
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── event ───────────────────────────────────────────────────
    function test_collect_emits_event() public {
    // 1. تخزين قيمة الرسوم المتولدة
    uint256 fees = _generateFees();

    // 2. تفعيل التحقق من العناوين الـ 3 المرمزة + البيانات (البارامتر الرابع true للتحقق من قيمة amount)
    vm.expectEmit(true, true, true, true);

    // 3. تمرير المعاملات الأربعة كاملة للحدث
    emit FeeCollector.CollectTriggered(poolId, Currency.unwrap(currency0), recipient, fees);

    // 4. تنفيذ العملية
    collector.collect(poolId, currency0, recipient);
}
}
