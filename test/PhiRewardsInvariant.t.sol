// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PhiRewards} from "../src/PhiRewards.sol";

contract PhiRewardsHandler is Test {
    using PhiRewards for PhiRewards.RewardPool;

    PhiRewards.RewardPool internal pool;
    PhiRewards.UserReward internal user0;
    PhiRewards.UserReward internal user1;
    PhiRewards.UserReward internal user2;

    uint256 public totalAdded;
    uint256 public totalWithdrawn;
    uint256 public lastRewardPerShare;
    bool[3] internal registered;

    function getTotalShares()    external view returns (uint256) { return pool.totalShares; }
    function getRewardPerShare() external view returns (uint256) { return pool.rewardPerShareX128; }
    function getBalance()        external view returns (uint256) { return pool.balance; }
    function getUser0Shares()    external view returns (uint256) { return user0.shares; }
    function getUser1Shares()    external view returns (uint256) { return user1.shares; }
    function getUser2Shares()    external view returns (uint256) { return user2.shares; }
    function getUser0Pending()   external view returns (uint256) { return user0.pending; }
    function getUser1Pending()   external view returns (uint256) { return user1.pending; }
    function getUser2Pending()   external view returns (uint256) { return user2.pending; }

    function addReward(uint256 amount) external {
        amount = bound(amount, 1, 1e27);
        pool.addReward(amount);
        totalAdded += amount;
        lastRewardPerShare = pool.rewardPerShareX128;
    }

    function registerUser(uint8 userId, uint128 liquidity, uint8 periods) external {
        userId    = uint8(bound(userId, 0, 2));
        liquidity = uint128(bound(liquidity, 1, 1e24));
        periods   = uint8(bound(periods, 0, 60));
        if (userId == 0) { pool.registerOrUpdate(user0, liquidity, periods); registered[0] = true; }
        if (userId == 1) { pool.registerOrUpdate(user1, liquidity, periods); registered[1] = true; }
        if (userId == 2) { pool.registerOrUpdate(user2, liquidity, periods); registered[2] = true; }
    }

    function exitUser(uint8 userId) external {
        userId = uint8(bound(userId, 0, 2));
        if (userId == 0 && registered[0]) { totalWithdrawn += pool.exit(user0); registered[0] = false; }
        if (userId == 1 && registered[1]) { totalWithdrawn += pool.exit(user1); registered[1] = false; }
        if (userId == 2 && registered[2]) { totalWithdrawn += pool.exit(user2); registered[2] = false; }
    }

    function harvestUser(uint8 userId) external {
        userId = uint8(bound(userId, 0, 2));
        if (userId == 0 && registered[0]) pool.harvest(user0);
        if (userId == 1 && registered[1]) pool.harvest(user1);
        if (userId == 2 && registered[2]) pool.harvest(user2);
    }
}

contract PhiRewardsInvariantTest is Test {

    PhiRewardsHandler internal handler;

    function setUp() public {
        handler = new PhiRewardsHandler();
        targetContract(address(handler));
    }

    function invariant_totalSharesConsistent() public view {
        assertEq(
            handler.getTotalShares(),
            handler.getUser0Shares() + handler.getUser1Shares() + handler.getUser2Shares(),
            "totalShares != sum of shares"
        );
    }

    function invariant_withdrawnNeverExceedsAdded() public view {
        assertLe(
            handler.totalWithdrawn(),
            handler.totalAdded(),
            "withdrawn > added"
        );
    }

    function invariant_pendingBounded() public view {
        assertLe(
            handler.getUser0Pending() + handler.getUser1Pending() + handler.getUser2Pending(),
            handler.totalAdded(),
            "pending > totalAdded"
        );
    }

    function invariant_rewardPerShareNonDecreasing() public view {
        assertGe(
            handler.getRewardPerShare(),
            handler.lastRewardPerShare(),
            "rewardPerShare decreased"
        );
    }

    function invariant_balanceBounded() public view {
        assertLe(
            handler.getBalance(),
            handler.totalAdded(),
            "balance > totalAdded"
        );
    }
}
