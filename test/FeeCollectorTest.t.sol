// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PhiHook} from "../src/PhiHook.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {PhiMath} from "../src/PhiMath.sol";

contract MockPMFull {
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;
    bool    public unlockCalled;

    function unlock(bytes calldata data) external returns (bytes memory) {
        unlockCalled = true;
        return IUnlockCB(msg.sender).unlockCallback(data);
    }
    function take(Currency, address to, uint256 amount) external {
        lastTakeRecipient = to;
        lastTakeAmount    = amount;
    }
    function mint(address, uint256, uint256) external {}
    function burn(address, uint256, uint256) external {}
}
interface IUnlockCB { function unlockCallback(bytes calldata) external returns (bytes memory); }

contract FeeCollectorTest is Test {
    PhiHook      hook;
    FeeCollector collector;
    MockPMFull   mockManager;

    address lp        = address(0xBEEF);
    address recipient = address(0xABCD);

    PoolKey  key;
    bytes32  poolId;
    Currency currency0;

    function setUp() public {
        mockManager = new MockPMFull();
        hook        = new PhiHook(IPoolManager(address(mockManager)), address(this));
        collector   = new FeeCollector(hook);
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

    /// @dev génère des treasury fees via afterSwap (a0 > 0 = token0 into pool)
    function _generateFees() internal returns (uint256) {
        // add liquidity first
        IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60,
            liquidityDelta: int256(uint256(1000e18)), salt: 0
        });
        vm.prank(address(mockManager));
        hook.afterAddLiquidity(lp, key, p,
            BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");

        // swap: a0 > 0 → token0 into pool → fee applies
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(100_000e18),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta swapDelta = BalanceDelta.wrap(
            (int256(100_000e18) << 128) | int256(0));
        vm.prank(address(mockManager));
        hook.afterSwap(address(0), key, sp, swapDelta, "");

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
        vm.expectRevert(PhiHook.PhiHook__ZeroFees.selector);
        collector.collect(poolId, currency0, recipient);
    }

    // ─── collectBatch ─────────────────────────────────────────────
    function test_collectBatch_only_owner() public {
        bytes32[] memory ids  = new bytes32[](1);
        ids[0] = poolId;
        Currency[] memory curs = new Currency[](1);
        curs[0] = currency0;
        vm.expectRevert(FeeCollector.FeeCollector__NotOwner.selector);
        vm.prank(address(0xBAD));
        collector.collectBatch(ids, curs, recipient);
    }

   function test_collectBatch_length_mismatch_reverts() public {
        bytes32[]  memory ids  = new bytes32[](2);
        Currency[] memory curs = new Currency[](1);
        
        // Change from a string message to the custom error selector
        vm.expectRevert(FeeCollector.FeeCollector__LengthMismatch.selector);
        
        collector.collectBatch(ids, curs, recipient);
    }

    function test_collectBatch_single_pool() public {
        _generateFees();
        bytes32[]  memory ids  = new bytes32[](1);
        ids[0] = poolId;
        Currency[] memory curs = new Currency[](1);
        curs[0] = currency0;
        collector.collectBatch(ids, curs, recipient);
        assertEq(hook.accruedFees(poolId), 0);
    }

    // ─── event ───────────────────────────────────────────────────
    function test_collect_emits_event() public {
        uint256 fees = _generateFees(); // Capture the generated fees
        
        // Change the 4th parameter to true to check unindexed data (amount)
        vm.expectEmit(true, true, true, true); 
        
        // Pass the 4th argument (fees) here:
        emit FeeCollector.CollectTriggered(poolId, Currency.unwrap(currency0), recipient, fees);
        
        collector.collect(poolId, currency0, recipient);
    }
}
