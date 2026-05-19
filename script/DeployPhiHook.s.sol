// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {PhiHook} from "../src/PhiHook.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

contract DeployPhiHook is Script {
    // عنوان عقد مصنع CREATE2 الموحد في Foundry / EVM
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // الأقنعة والرايات الخاصة بـ Uniswap V4 Hooks
    uint160 constant ALL_MASK = 0x3FFF;
    
    // الرايات المستهدفة لعقد الـ PhiHook الخاص بك (تعدل تلقائياً بناءً على الـ Hooks المفعلة)
    // ملاحظة: إذا كان لديك قيمة Hex ثابتة من ملفك القديم (مثل 0x2A80)، يمكنك وضعها هنا مباشرة.
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | 
                             Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
                             Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
                             Hooks.BEFORE_SWAP_FLAG;

    function run() external {
        address POOL_MANAGER = vm.envAddress("POOL_MANAGER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        // 1️⃣ حساب الـ Bytecode بدقة مدمجاً معه المعاملين الجديدين لضمان دقة التنقيب عن الـ Salt
        bytes memory creationCode = abi.encodePacked(
            type(PhiHook).creationCode,
            abi.encode(POOL_MANAGER, deployerAddress)
        );
        bytes32 codeHash = keccak256(creationCode);

        console.log("Starting Salt Mining for PhiHook...");
        (address expectedAddress, bytes32 salt) = _mine(CREATE2_DEPLOYER, codeHash);

        console.log("Mined Salt (uint256): ", uint256(salt));
        console.log("Expected Address:    ", expectedAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 2️⃣ النشر الفعلي باستخدام الـ Salt الجديد والمعاملين لتطابق قناع العناوين
        PhiHook hook = new PhiHook{salt: salt}(IPoolManager(POOL_MANAGER), deployerAddress);
        console.log("PhiHook Deployed at: ", address(hook));

        // التحقق الصارم من الـ Flags بعد النشر
        require(
            (uint160(address(hook)) & ALL_MASK) == FLAGS,
            "Critical: flags mismatch after deployment"
        );
        console.log("FLAGS VERIFIED: OK");

        // 3️⃣ نشر الـ FeeCollector وتفويضه بأمان تحت المالك الحقيقي (محفظتك)
        FeeCollector collector = new FeeCollector(hook);
        console.log("FeeCollector Deployed at:", address(collector));

        hook.setCollector(address(collector));
        console.log("FeeCollector authorized successfully.");

        vm.stopBroadcast();
    }

    // آلية التعدين والتنقيب التلقائي عن Salt متوافق مع شروط Uniswap V4
    function _mine(address deployer, bytes32 codeHash) internal pure returns (address, bytes32) {
        for (uint256 i = 0; i < 10_000_000; i++) {
            bytes32 salt = bytes32(i);
            address addr = previewAddress(deployer, salt, codeHash);
            
            if ((uint160(addr) & ALL_MASK) == FLAGS) {
                return (addr, salt);
            }
        }
        revert("Salt not found for specified flags");
    }

    // محاكاة حساب العنوان قبل النشر الفعلي على الشبكة
    function previewAddress(address deployer, bytes32 salt, bytes32 codeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
    }
}
