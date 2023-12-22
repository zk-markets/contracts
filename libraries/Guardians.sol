// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./Base.sol";


interface IRegistry {
    function addGuardians(address[] memory guardians) external;
    function removeGuardians(address[] memory guardians) external;
    function changeOwner(address newOwner) external;
}

// BaseStorage Contract
contract Guardians is Base {
    // State variable to store the address of the Registry contract
    IRegistry public registry;

    uint private ONE_DAY = 24 hours;

    // Delay 
    //uint256 constant DELAYED_BLOCK_TIME_48 = 1; // Equivalent to 48 hours assuming 1 block per second 172800
    //uint256 constant DELAYED_BLOCK_TIME_24 = 1; // Equivalent to 24 hours assuming 1 block per second 86400
    uint256 constant DELAYED_TIME_24H = 24 hours;
    uint256 constant DELAYED_TIME_48H = 48 hours;

    // Is account locked
    bool public isLocked = false;

    // Guardians count
    uint256 public guardiansCount = 0;

    // Guardians array
    address[] public guardiansList;

    // State variables to store the timestamps
    uint256 public guardianAdditionTimestamp;
    uint256 public guardianRemovalTimestamp;
    uint256 public guardianAdditionCancellationTimestamp;
    uint256 public guardianRemovalCancellationTimestamp;

    // Track which new signer each guardian has agreed to
    mapping(address => address) public guardiansSignerChoice;

    // Track how many guardians agreed to unlock Smart Account
    mapping(address => uint256) public guardiansUnlockAgreementCount;

    // Guardians mapping
    mapping(address => bool) public isGuardian;

    // Track the guardian that the owner or a guardian wishes to remove.
    mapping(address => address) public explicitRemovalVote;

    // Track if Guardian agreed to unlock account
    mapping(address => bool) public guardiansUnlockVote;

    /**************************************************************************
     * Events
     **************************************************************************/

    // Log the initiation of Guardian addition
    event GuardianAdditionInitiated(address indexed owner, bool indexed initiated);

    // Log the initiation of Guardian removal
    event GuardianRemovalInitiated(address indexed owner, bool indexed initiated);

    // Log the cancellation of Guardian addition
    event GuardianAdditionCancelled(address indexed guardian);

    // Log the cancellation of Guardian cancellation
    event GuardianRemovalCancelled(address indexed guardian);

    // Log the addition of new guardians
    event GuardianAdded(address indexed newGuardian);

    // Log change of vote for new signer
    event GuardianVotedForSignerChange(address indexed guardian, address indexed newSigner);

    // Log the change of the owner
    event SignerChanged(address indexed oldOwner, address indexed newOwner);

    // Log voter, guardian to be removed, previous vote (if any)
    event VotedForGuardianRemoval(address indexed voter, address indexed guardianToRemove);

    // Log address of removed Guardian
    event GuardianRemoved(address indexed guardian);

    // Log the locking and unlocking of the account
    event AccountLocked();
    event AccountUnlocked();


    // constructor
    constructor(address _owner, address _registryAddress) {
        registry = IRegistry(_registryAddress);

        // Add the owner as a guardian
        address[] memory ownerAsGuardian = new address[](1);
        ownerAsGuardian[0] = _owner;
        _addGuardians(ownerAsGuardian);
    }

    // Caller = Guardian
    modifier onlyGuardian() {
        require(isGuardian[msg.sender], "Caller is not a guardian");
        _;
    }

    // Check to see if account is locked
    modifier isUnlocked() {
        require(!isLocked, "Account is locked");
        _;
    }

    modifier requiresUnlockGuardians() {
        require(guardiansUnlockAgreementCount[address(this)] >= (guardiansCount + 1) / 2, "Not enough guardian approvals for unlock");
        _;
    }
    

    /**************************************************************************
     * Account Locking & Unlocking
     **************************************************************************/

    // Lock the account, can be called by any guardian
    function lockAccount() external onlyGuardian {
        require(!isLocked, "Account is already locked");
        isLocked = true;
        emit AccountLocked();
    }

    function unlockAccount() external onlyGuardian {
        require(isLocked, "Account is not locked");
        require(!guardiansUnlockVote[msg.sender], "Guardian has already voted to unlock");

        // Record the guardian's vote
        guardiansUnlockVote[msg.sender] = true;

        uint256 count = 0;
        for (uint256 i = 0; i < guardiansList.length; i++) {
            if (guardiansUnlockVote[guardiansList[i]]) {
                count++;
            }
        }

        if (count >= (guardiansCount + 1) / 2) {
            isLocked = false;

            // Reset all guardian votes
            for (uint256 i = 0; i < guardiansList.length; i++) {
                guardiansUnlockVote[guardiansList[i]] = false;
            }

            emit AccountUnlocked();
        }
    }

    /**************************************************************************
     * Signer management
     **************************************************************************/

    function changeSigner(address newSigner) external onlyGuardian {
        require(isGuardian[msg.sender], "Only guardians can agree to change signer");
        require(guardiansSignerChoice[msg.sender] != newSigner, "Guardian has already agreed to this signer");

        // Record the guardian's choice
        guardiansSignerChoice[msg.sender] = newSigner;

        // Count the number of guardians who have chosen the `newSigner`
        uint256 count = 0;
        for (uint256 i = 0; i < guardiansList.length; i++) {
            if (guardiansSignerChoice[guardiansList[i]] == newSigner) {
                count++;
            }
        }

        // Check if over half of the guardians have chosen the `newSigner`
        if (count >= (guardiansCount + 1) / 2) {
            address oldOwner = owner;

            address[] memory guardianToRemove = new address[](1);
            guardianToRemove[0] = oldOwner;
            _guardianRemoval(guardianToRemove);

            owner = newSigner;

            // Add the new owner as a guardian if not already a guardian
            if (!isGuardian[newSigner]) {
                address[] memory newGuardian = new address[](1);
                newGuardian[0] = newSigner;
                _addGuardians(newGuardian);
            }

            // Reset the guardians choices
            for (uint256 i = 0; i < guardiansList.length; i++) {
                delete guardiansSignerChoice[guardiansList[i]];
            }

            // Update the Registry
            registry.changeOwner(newSigner);
            emit SignerChanged(oldOwner, newSigner);

        } else {
            emit GuardianVotedForSignerChange(msg.sender, newSigner);
        }
    }

    /**************************************************************************
     * Guardian Management
     **************************************************************************/

    /**
    * @notice Allows the contract's owner to initiate the process of adding a guardian.
    * @notice Allows the contract's owner to add new guardians to the contract.
    * @param newGuardians An array of addresses representing the new guardians to be added.
    */
    function addGuardians(address[] memory newGuardians) external onlyOwnerOrSelf {
        // Check if there are no guardians already added
        if (guardiansCount <= 1) {
            // If this is the first time adding guardians, add them immediately without any additional checks
            _addGuardians(newGuardians);
            return;
        } 
        
        // If there are existing guardians:
        if(guardianAdditionTimestamp == 0) {
            // If the guardian addition process hasn't been initiated, initiate it and return
            require(block.timestamp - guardianAdditionCancellationTimestamp >= DELAYED_TIME_24H, "24h since last cancel not passed");
            guardianAdditionTimestamp = block.timestamp;
            emit GuardianAdditionInitiated(msg.sender, true);
            return;
        }
        
        // If the guardian addition process has been initiated, ensure that the required time has passed
        require(block.timestamp - guardianAdditionTimestamp >= DELAYED_TIME_24H, "24h not passed since initiation");
        
        // Add the new guardians
        _addGuardians(newGuardians);
        
        // Reset the guardian addition timestamps, indicating the process is complete
        guardianAdditionTimestamp = 0;
        guardianAdditionCancellationTimestamp = 0;
    }

    /**
    * @notice private function to add new guardians to the contract's list of guardians.
    * @param newGuardians An array of addresses representing the new guardians to be added.
    */
    function _addGuardians(address[] memory newGuardians) private {
        // Iterate over each address in the newGuardians array
        for (uint256 i = 0; i < newGuardians.length; i++) {
            // Ensure that the provided guardian address is not the zero address
            require(newGuardians[i] != address(0), "Cannot add zero address as guardian");

            // Ensure that the provided address is not already a guardian
            require(!isGuardian[newGuardians[i]], "Address already a guardian");

            // Mark the provided address as a guardian
            isGuardian[newGuardians[i]] = true;

            // Add the provided guardian address to the guardiansList
            guardiansList.push(newGuardians[i]);

            // Increment the total count of guardians
            guardiansCount++;
            

            // Emit an event to log the addition of the new guardian
            emit GuardianAdded(newGuardians[i]);
        }

        // Update the Registry
        registry.addGuardians(newGuardians);
    }

    /**
    * @notice Allows a Guardian to cancel the ongoing guardian addition process.
    */
    function cancelGuardianAddition() external onlyGuardian {
        // Reset the guardian addition timestamp, effectively cancelling the addition process
        guardianAdditionTimestamp = 0;

        // Set the timestamp for the next time a guardian addition can be initiated to the current time
        guardianAdditionCancellationTimestamp = block.timestamp;

        // Emit an event to log the cancellation of the guardian addition process by the calling guardian
        emit GuardianAdditionCancelled(msg.sender);
    }

    /**
    * @notice Allows the contract's owner to initiate the process of removing a guardian.
    * @notice Allows the contract's owner to execute the removal of specified guardians.
    * @param guardiansToRemove An array of addresses representing the guardians to be removed.
    */
    function executeGuardianRemoval(address[] memory guardiansToRemove) external {
        require(msg.sender == owner, "Only the owner can remove");
        
        if(guardianRemovalTimestamp == 0) {
            // If the removal process hasn't been initiated, initiate it and return
            require(block.timestamp - guardianRemovalCancellationTimestamp >= DELAYED_TIME_24H, "24h since last cancel not passed");
            guardianRemovalTimestamp = block.timestamp;
            emit GuardianRemovalInitiated(msg.sender, true);
            return;
        }
        
        // If the removal process has been initiated, ensure that the required time has passed
        require(block.timestamp - guardianRemovalTimestamp >= DELAYED_TIME_48H, "48h not passed since initiation");
        
        _guardianRemoval(guardiansToRemove);
        
        // Reset the removal countdowns, indicating the removal process is complete
        guardianRemovalTimestamp = 0;
        guardianRemovalCancellationTimestamp = 0;
    }

    function _guardianRemoval(address[] memory guardiansToRemove) private {
        // Iterate over each address in the guardiansToRemove array
        for (uint256 i = 0; i < guardiansToRemove.length; i++) {
            // Ensure that the provided address is indeed a guardian
            require(isGuardian[guardiansToRemove[i]], "Address not a guardian");

            // Mark the provided address as no longer being a guardian
            isGuardian[guardiansToRemove[i]] = false;

            // Decrement the total count of guardians
            guardiansCount--;

            bool removed = false;

            // Look for the guardian in the guardiansList array
            for (uint256 j = 0; j < guardiansList.length; j++) {
                if (guardiansList[j] == guardiansToRemove[i]) {
                    // Replace the guardian with the last one in the list
                    guardiansList[j] = guardiansList[guardiansList.length - 1];
                    
                    // Remove the last entry (now a duplicate)
                    guardiansList.pop();

                    removed = true;
                    break;
                }
            }

            // Ensure that the guardian was found and removed from the list
            require(removed, "Guardian not found in list");
        }

        // Update the Registry
        registry.removeGuardians(guardiansToRemove);
    }

    /**
    * @notice Allows a Guardian to cancel the ongoing guardian removal process.
    */
    function cancelGuardianRemoval() external onlyGuardian {
        // Reset the guardian removal countdown, effectively cancelling the removal process
        guardianRemovalTimestamp = 0;

        // Set the countdown for the next time a guardian removal can be initiated to the current timestamp
        guardianRemovalCancellationTimestamp = block.timestamp;

        // Emit an event to log the cancellation of the guardian removal process by the owner
        emit GuardianRemovalCancelled(msg.sender);
    }

    /**
    * @notice Allows the contract's owner or any guardian to cast a vote for the removal of a specific guardian.
    * @param guardianToRemove The address of the guardian being voted for removal.
    */
    function removeGuardianExplicitly(address guardianToRemove) external {
        require(isGuardian[guardianToRemove], "Provided address is not a guardian");
        require(msg.sender != guardianToRemove, "Cannot remove self");
        require(msg.sender == owner || isGuardian[msg.sender], "Only owner or guardians can call this");

        // If the guardian is voting for the same guardian to remove, do nothing.
        if(explicitRemovalVote[msg.sender] == guardianToRemove) return;

        // Update the guardian's vote.
        explicitRemovalVote[msg.sender] = guardianToRemove;
        emit VotedForGuardianRemoval(msg.sender, guardianToRemove);

        // Recalculate the vote count for the guardianToRemove.
        uint256 count = 0;
        for (uint256 i = 0; i < guardiansList.length; i++) {
            if (explicitRemovalVote[guardiansList[i]] == guardianToRemove) {
                count++;
            }
        }

        uint256 threshold = (guardiansCount + 1) / 2;
        if (count >= threshold) {
            isGuardian[guardianToRemove] = false;
            
            // Find and remove the guardian from the guardiansList.
            for (uint256 i = 0; i < guardiansList.length; i++) {
                if (guardiansList[i] == guardianToRemove) {
                    guardiansList[i] = guardiansList[guardiansList.length - 1];
                    guardiansList.pop();
                    break;
                }
            }
            guardiansCount--;

            emit GuardianRemoved(guardianToRemove);

            // Update the Registry
            address[] memory guardiansToRemove = new address[](1);
            guardiansToRemove[0] = guardianToRemove;
            registry.removeGuardians(guardiansToRemove);

            // Resetting votes.
            for (uint256 i = 0; i < guardiansList.length; i++) {
                delete explicitRemovalVote[guardiansList[i]];
            }
        }
    }
}