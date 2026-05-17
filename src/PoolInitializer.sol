// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";

/// @title PoolInitializer
/// @notice ينشئ Uniswap V4 pool مع PhiHook
/// @dev initialize() لا تحتاج unlock — تُستدعى مباشرة
contract PoolInitializer {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    event PoolCreated(
        bytes32 indexed poolId,
        address indexed token0,
        address indexed token1,
        uint24  fee,
        int24   tickSpacing,
        address hook,
        uint160 sqrtPriceX96,
        int24   tick
    );

    error PoolInitializer__InvalidTokenOrder();
    error PoolInitializer__InvalidFee();

    constructor(IPoolManager _manager) {
        poolManager = _manager;
    }

    /// @notice ينشئ pool جديد مع PhiHook
    /// @param token0 العملة الأولى (يجب أن تكون < token1 عنواناً)
    /// @param token1 العملة الثانية
    /// @param fee رسوم الـ pool (مثلاً 3000 = 0.3%)
    /// @param tickSpacing المسافة بين الـ ticks (60 لـ 0.3%)
    /// @param hook عنوان PhiHook
    /// @param sqrtPriceX96 السعر الابتدائي بصيغة Q64.96
    /// @return key مفتاح الـ pool
    /// @return tick الـ tick الابتدائي
    function createPool(
        address token0,
        address token1,
        uint24  fee,
        int24   tickSpacing,
        address hook,
        uint160 sqrtPriceX96
    ) external returns (PoolKey memory key, int24 tick) {
        // V4 يشترط token0 < token1
        if (token0 >= token1) revert PoolInitializer__InvalidTokenOrder();
        if (fee > 1_000_000) revert PoolInitializer__InvalidFee();

        key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         fee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(hook)
        });

        // initialize لا تحتاج unlock
        tick = poolManager.initialize(key, sqrtPriceX96);

        emit PoolCreated(
            keccak256(abi.encode(key)),
            token0,
            token1,
            fee,
            tickSpacing,
            hook,
            sqrtPriceX96,
            tick
        );
    }

    /// @notice يحسب sqrtPriceX96 من سعر token1/token0
    /// @param price السعر بـ 1e18 (مثلاً 1e18 = السعر 1:1)
    /// @return sqrtPriceX96 السعر بصيغة Q64.96
    function priceToSqrtX96(uint256 price) external pure returns (uint160) {
        // sqrtPriceX96 = sqrt(price) × 2^96
        // price بـ 1e18 → نقسم على 1e18 ثم نضرب في 2^96
        // نستخدم: sqrtPriceX96 = sqrt(price × 2^192 / 1e18)
        uint256 ratioX192 = (price << 192) / 1e18;
        return uint160(_sqrt(ratioX192));
    }

    /// @notice أسعار شائعة جاهزة
    function sqrtPriceX96_1_1() external pure returns (uint160) {
        // السعر 1:1
        return 79228162514264337593543950336; // = 2^96
    }

    function sqrtPriceX96_1_2() external pure returns (uint160) {
        // token1 = ضعف token0 (سعر 0.5)
        return 56022770974786139918731938227; // = 2^96 / sqrt(2)
    }

    function sqrtPriceX96_2_1() external pure returns (uint160) {
        // token0 = ضعف token1 (سعر 2)
        return 112045541949572279837463876454; // = 2^96 × sqrt(2)
    }

    // ─── Internal ─────────────────────────────────────────────────
    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
