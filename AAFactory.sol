// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@matterlabs/zksync-contracts/l2/system-contracts/Constants.sol";
import "@matterlabs/zksync-contracts/l2/system-contracts/libraries/SystemContractsCaller.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IRegistry {
    function registerSmartAccount(address owner, address smartAccount) external;
}

contract AAFactory is Ownable {
    bytes32 public aaBytecodeHash;
    // Registry of Smart Accounts
    IRegistry public registry;

    event SmartAccountDeployed(address indexed user, address smartAccount);

    constructor(bytes32 _aaBytecodeHash, address _registryAddress) Ownable(msg.sender) {
        aaBytecodeHash = _aaBytecodeHash;
        registry = IRegistry(_registryAddress);
    }

    function deployAccount(
        bytes32 salt,
        address owner
    ) external returns (address accountAddress) {
        address _registryAddress = address(registry);
        (bool success, bytes memory returnData) = SystemContractsCaller
            .systemCallWithReturndata(
                uint32(gasleft()),
                address(DEPLOYER_SYSTEM_CONTRACT),
                uint128(0), 
                abi.encodeCall(
                    DEPLOYER_SYSTEM_CONTRACT.create2Account,
                    (salt, aaBytecodeHash, abi.encode(owner, _registryAddress), IContractDeployer.AccountAbstractionVersion.Version1)
                )
            );
        require(success, "Deployment failed");

        (accountAddress) = abi.decode(returnData, (address));
        registry.registerSmartAccount(owner, accountAddress);
        emit SmartAccountDeployed(owner, accountAddress);
    }
}
