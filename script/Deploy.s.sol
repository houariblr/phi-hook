// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PhiHook} from "../src/PhiHook.sol";

contract DeployPhiHook is Script {

    // afterAddLiquidity=1024 + beforeRemoveLiquidity=512 + afterSwap=64
    uint160 constant FLAGS    = uint160(1024 + 512 + 64 + 1); // 0x641
    uint160 constant ALL_MASK = uint160((1 << 14) - 1);

    // Foundry's Create2Deployer على Anvil
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address POOL_MANAGER = vm.envOr(
            "POOL_MANAGER",
            address(0x1234567890123456789012345678901234567890)
        );

        bytes memory creationCode = abi.encodePacked(
            type(PhiHook).creationCode,
            abi.encode(POOL_MANAGER)
        );
        bytes32 codeHash = keccak256(creationCode);

        // نحسب CREATE2 بعنوان CREATE2_DEPLOYER (كما يفعل forge)
        (address hookAddress, bytes32 salt) = _mine(CREATE2_DEPLOYER, codeHash);

        console.log("Salt (uint256):   ", uint256(salt));
        console.log("Mined address:    ", hookAddress);
        console.log("Flags match:      ", (uint160(hookAddress) & ALL_MASK) == FLAGS);

        vm.startBroadcast();

        PhiHook hook = new PhiHook{salt: salt}(IPoolManager(POOL_MANAGER));
        console.log("Deployed at:      ", address(hook));

        // التحقق من الـ flags فقط (العنوان قد يختلف طفيفاً بسبب deployer)
        require(
            (uint160(address(hook)) & ALL_MASK) == FLAGS,
            "flags mismatch"
        );
        console.log("FLAGS OK");

        vm.stopBroadcast();
    }

    function _mine(address deployer, bytes32 codeHash)
        internal pure returns (address found, bytes32 salt)
    {
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            address candidate = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                deployer,
                salt,
                codeHash
            )))));
            if ((uint160(candidate) & uint160((1 << 14) - 1)) == FLAGS) {
                return (candidate, salt);
            }
        }
        revert("no salt found");
    }
}
