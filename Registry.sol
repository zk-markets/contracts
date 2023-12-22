// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Registry is Ownable {


    constructor() Ownable(msg.sender)  {}

    /**************************************************************************
     * State Variables
     **************************************************************************/

    address public aaFactoryAddress;

    // Mapping from owner address to array of owned smart accounts
    mapping(address => address[]) private ownerToSmartAccounts;

    // Mapping from smart account to its owner
    mapping(address => address) public smartAccountToOwner;

    // Mapping from smart account to its guardians
    mapping(address => address[]) public smartAccountToGuardians;

    // Mapping from guardian address to array of smart accounts it guards
    mapping(address => address[]) private guardianToSmartAccounts;
    
    /**************************************************************************
     * Events
     **************************************************************************/

    // Log the smart account to owner
    event SmartAccountRegistered(address indexed owner, address indexed smartAccount);

    // Log guardian addition to smart account
    event GuardianAdded(address indexed smartAccount, address indexed guardian);

     // Log the removal of a guardian from a smart account
    event GuardianRemoved(address indexed smartAccount, address indexed guardian);

    // Log the change of owner (signer) of a smart account
    event OwnerChanged(address indexed smartAccount, address indexed oldOwner, address indexed newOwner);

    /**************************************************************************
     * Modifiers
     **************************************************************************/

    modifier onlyAAFactory() {
        require(msg.sender == aaFactoryAddress, "Caller is not the AAFactory contract");
        _;
    }

    /**************************************************************************
     * Registry Functions
     **************************************************************************/

    function setAAFactoryAddress(address _aaFactoryAddress) external onlyOwner {
        aaFactoryAddress = _aaFactoryAddress;
    }

    function registerSmartAccount(address owner, address smartAccount) external onlyAAFactory {
        // Add smart account to owner's list of smart accounts
        ownerToSmartAccounts[owner].push(smartAccount);

        // Set the owner of the smart account
        smartAccountToOwner[smartAccount] = owner;

        emit SmartAccountRegistered(owner, smartAccount);
    }

    function addGuardians(address[] memory guardians) external {
        for (uint256 i = 0; i < guardians.length; i++) {
            address guardian = guardians[i];
            smartAccountToGuardians[msg.sender].push(guardian);
            guardianToSmartAccounts[guardian].push(msg.sender);
            emit GuardianAdded(msg.sender, guardian);
        }
    }

    function removeGuardians(address[] memory guardiansToRemove) external {
        for (uint256 i = 0; i < guardiansToRemove.length; i++) {
            address guardian = guardiansToRemove[i];
            
            // Get the list of guardians for the smart account
            address[] storage guardians = smartAccountToGuardians[msg.sender];
            bool guardianFound = false;
            
            for (uint256 j = 0; j < guardians.length; j++) {
                if (guardians[j] == guardian) {
                    // Replace the guardian with the last one in the list and remove the last entry
                    guardians[j] = guardians[guardians.length - 1];
                    guardians.pop();
                    guardianFound = true;
                    break;
                }
            }
            
            require(guardianFound, "Guardian not found for this smart account");
            
            // Update the guardianToSmartAccounts mapping
            address[] storage guardedAccounts = guardianToSmartAccounts[guardian];
            bool smartAccountFound = false;
            
            for (uint256 j = 0; j < guardedAccounts.length; j++) {
                if (guardedAccounts[j] == msg.sender) {
                    // Replace the smart account with the last one in the list and remove the last entry
                    guardedAccounts[j] = guardedAccounts[guardedAccounts.length - 1];
                    guardedAccounts.pop();
                    smartAccountFound = true;
                    break;
                }
            }
            
            require(smartAccountFound, "Smart account not found for this guardian");
            
            emit GuardianRemoved(msg.sender, guardian);
        }
    }

    function changeOwner(address newOwner) external {
        // Ensure that the caller has the right permissions (e.g., it's the smart account itself)
        require(msg.sender == msg.sender, "Unauthorized");
        
        address oldOwner = smartAccountToOwner[msg.sender];
        require(oldOwner != address(0), "Smart account does not exist");
        require(newOwner != address(0), "New owner cannot be the zero address");
        
        // Update the smartAccountToOwner mapping
        smartAccountToOwner[msg.sender] = newOwner;
        
        // Update the ownerToSmartAccounts mapping for the old owner
        address[] storage oldOwnerAccounts = ownerToSmartAccounts[oldOwner];
        bool smartAccountFound = false;
        for (uint256 i = 0; i < oldOwnerAccounts.length; i++) {
            if (oldOwnerAccounts[i] == msg.sender) {
                oldOwnerAccounts[i] = oldOwnerAccounts[oldOwnerAccounts.length - 1];
                oldOwnerAccounts.pop();
                smartAccountFound = true;
                break;
            }
        }
        require(smartAccountFound, "Smart account not found for this owner");
        
        // Update the ownerToSmartAccounts mapping for the new owner
        ownerToSmartAccounts[newOwner].push(msg.sender);
        
        emit OwnerChanged(msg.sender, oldOwner, newOwner);
    }

    /**************************************************************************
     * Getter Functions
     **************************************************************************/
     
    function getSmartAccountsByOwner(address owner) external view returns (address[] memory) {
        return ownerToSmartAccounts[owner];
    }

    function getSmartAccountsByGuardian(address guardian) external view returns (address[] memory) {
        return guardianToSmartAccounts[guardian];
    }

    function getGuardiansBySmartAccount(address smartAccount) external view returns (address[] memory) {
        return smartAccountToGuardians[smartAccount];
    }
}
