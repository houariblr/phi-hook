// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PoolInitializer} from "../src/PoolInitializer.sol";
import {PhiHook} from "../src/PhiHook.sol";

contract MockPoolManagerInit {
    int24 public constant TICK = 0;
    event Initialize(bytes32 poolId, uint160 sqrtPriceX96);

    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external returns (int24)
    {
        emit Initialize(keccak256(abi.encode(key)), sqrtPriceX96);
        return TICK;
    }
}

contract PoolInitializerTest is Test {
    PoolInitializer initializer;
    MockPoolManagerInit mockManager;
    address hook = address(0x641); // عنوان وهمي بـ flags صحيحة

    address token0 = address(0x1000);
    address token1 = address(0x2000);

    function setUp() public {
        mockManager = new MockPoolManagerInit();
        initializer = new PoolInitializer(IPoolManager(address(mockManager)));
    }

    // ─── createPool ───────────────────────────────────────────────
    function test_createPool_success() public {
        (PoolKey memory key, int24 tick) = initializer.createPool(
            token0, token1, 3000, 60, hook,
            initializer.sqrtPriceX96_1_1()
        );
        assertEq(Currency.unwrap(key.currency0), token0);
        assertEq(Currency.unwrap(key.currency1), token1);
        assertEq(key.fee, 3000);
        assertEq(key.tickSpacing, 60);
        assertEq(tick, 0);
    }

    function test_createPool_invalid_token_order() public {
        uint160 sqrtPrice = initializer.sqrtPriceX96_1_1();
        vm.expectRevert(PoolInitializer.PoolInitializer__InvalidTokenOrder.selector);
        initializer.createPool(token1, token0, 3000, 60, hook, sqrtPrice);
    }

    function test_createPool_equal_tokens_reverts() public {
        uint160 sqrtPrice = initializer.sqrtPriceX96_1_1();
        vm.expectRevert(PoolInitializer.PoolInitializer__InvalidTokenOrder.selector);
        initializer.createPool(token0, token0, 3000, 60, hook, sqrtPrice);
    }

    function test_createPool_invalid_fee() public {
        uint160 sqrtPrice = initializer.sqrtPriceX96_1_1();
        vm.expectRevert(PoolInitializer.PoolInitializer__InvalidFee.selector);
        initializer.createPool(token0, token1, 1_000_001, 60, hook, sqrtPrice);
    }

    function test_createPool_emits_event() public {
        vm.recordLogs();
        initializer.createPool(
            token0, token1, 3000, 60, hook,
            initializer.sqrtPriceX96_1_1()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // PoolCreated event موجود
        assertTrue(logs.length > 0);
    }

    // ─── sqrtPrice helpers ────────────────────────────────────────
    function test_sqrtPriceX96_1_1() public view {
        uint160 price = initializer.sqrtPriceX96_1_1();
        // 2^96 = 79228162514264337593543950336
        assertEq(price, 79228162514264337593543950336);
    }

    function test_sqrtPriceX96_values_ordered() public view {
        uint160 half  = initializer.sqrtPriceX96_1_2();
        uint160 one   = initializer.sqrtPriceX96_1_1();
        uint160 two   = initializer.sqrtPriceX96_2_1();
        // half < one < two
        assertTrue(half < one);
        assertTrue(one < two);
    }

    function test_priceToSqrtX96_one() public view {
        // السعر 1:1 → sqrtPriceX96 = 2^96
        uint160 result = initializer.priceToSqrtX96(1e18);
        uint160 expected = initializer.sqrtPriceX96_1_1();
        // نسمح بهامش 0.01% بسبب integer sqrt
        uint256 diff = result > expected ? result - expected : expected - result;
        assertTrue(diff * 10000 / expected < 1); // < 0.01%
    }

    function test_poolId_deterministic() public {
        (PoolKey memory key1,) = initializer.createPool(
            token0, token1, 3000, 60, hook,
            initializer.sqrtPriceX96_1_1()
        );
        (PoolKey memory key2,) = initializer.createPool(
            token0, token1, 3000, 60, hook,
            initializer.sqrtPriceX96_1_1()
        );
        assertEq(keccak256(abi.encode(key1)), keccak256(abi.encode(key2)));
    }
}
