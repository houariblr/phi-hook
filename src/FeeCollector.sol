// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {PhiHook} from "./PhiHook.sol";

/// @title  FeeCollector
/// @notice Access-control façade for withdrawing treasury fees from PhiHook.
///
/// @dev    ## Why this contract exists
///
///         PhiHook.collectFees() is protected by a two-address allowlist:
///         the immutable `owner` and the mutable `approvedCollector`.
///
///         Deploying FeeCollector as `approvedCollector` means:
///           • The hook's owner retains a fallback withdrawal path.
///           • Treasury management can be delegated without transferring
///             ownership of the hook itself.
///           • FeeCollector is upgradeable: owner calls hook.setCollector()
///             and no accrued fees are lost.
///
///         ## Token flow (no approvals, no transferFrom)
///
///         FeeCollector.collect()
///           └─► PhiHook.collectFees()
///                 └─► poolManager.unlock()
///                       └─► PhiHook._unlockCallback()
///                             ├─ poolManager.burn(hook, id, amount)  → +delta
///                             └─ poolManager.take(currency, recipient, amount) → -delta
///                                net delta = 0  ✓
///
///         Tokens are delivered directly to `recipient` by PoolManager.
///         FeeCollector never holds or touches ERC-20 tokens.
///
///         ## Scope
///         This contract handles TREASURY fees (accruedFees mapping).
///         LP reward claims are made directly by LPs via PhiHook.claimRewards().
contract FeeCollector {

    // ─── State ────────────────────────────────────────────────────

    PhiHook public immutable hook;
    address   public immutable owner;

    // ─── Errors ───────────────────────────────────────────────────

    error FeeCollector__NotOwner();
    error FeeCollector__ZeroAddress();
    error FeeCollector__LengthMismatch();

    // ─── Events ───────────────────────────────────────────────────

    event CollectTriggered(
        bytes32 indexed poolId,
        address indexed currency,
        address indexed recipient,
        uint256         amount
    );
    event BatchSkipped(bytes32 indexed poolId); // pool كان رصيده صفر

    // ─── Constructor ──────────────────────────────────────────────

    constructor(PhiHook _hook) {
        if (address(_hook) == address(0)) revert FeeCollector__ZeroAddress();
        hook  = _hook;
        owner = msg.sender;
    }

    // ─── External ─────────────────────────────────────────────────

    /// @notice Withdraw treasury fees for a single pool.
    /// @param  poolId    keccak256(abi.encode(PoolKey))
    /// @param  currency  ERC-20 token to withdraw (currency0 of the pool)
    /// @param  recipient Destination address
    function collect(
        bytes32  poolId,
        Currency currency,
        address  recipient
    ) external {
        if (msg.sender != owner) revert FeeCollector__NotOwner();
        if (recipient == address(0)) revert FeeCollector__ZeroAddress();

        uint256 amount = hook.accruedFees(poolId);
        emit CollectTriggered(
            poolId, Currency.unwrap(currency), recipient, amount);

        // PhiHookV2 validates approvedCollector, zeroes accruedFees (CEI),
        // then burns ERC-6909 claims and takes real tokens to recipient.
        hook.collectFees(poolId, currency, recipient);
    }

    /// @notice Withdraw treasury fees for multiple pools in one tx.
    ///
    /// @dev    Pools with zero fees are SKIPPED (not reverted) so a single
    ///         empty pool never blocks collection for the entire batch.
    ///         Emits BatchSkipped for each skipped pool — callers can monitor.
    ///
    /// @param  poolIds    Pool identifiers (keccak256 of PoolKey)
    /// @param  currencies Corresponding ERC-20 tokens (must be same length)
    /// @param  recipient  Single destination for all collected fees
    function collectBatch(
        bytes32[]  calldata poolIds,
        Currency[] calldata currencies,
        address    recipient
    ) external {
        if (msg.sender != owner) revert FeeCollector__NotOwner();
        if (recipient == address(0)) revert FeeCollector__ZeroAddress();
        if (poolIds.length != currencies.length)
            revert FeeCollector__LengthMismatch();

        uint256 n = poolIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = hook.accruedFees(poolIds[i]);

            // تخطى pool بدون رصيد بدلاً من revert
            if (amount == 0) {
                emit BatchSkipped(poolIds[i]);
                continue;
            }

            emit CollectTriggered(
                poolIds[i],
                Currency.unwrap(currencies[i]),
                recipient,
                amount
            );
            hook.collectFees(poolIds[i], currencies[i], recipient);
        }
    }
}
