//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./ERC721Template.sol";

contract ERC721Merkle is ERC721Template {
    uint256 public presalePrice;
    uint256 public presaleStartTime = type(uint256).max;
    mapping(uint256 => bytes32) private presaleMerkleRoots;
    uint256[] private tiers;
    mapping(address => uint256) private presaleMints;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        uint256 _maxSupply,
        uint256 _publicPrice,
        string memory _defaultBaseURI,
        string memory _notRevealedURI,
        address _comissionRecipient,
        uint256 _fixedCommisionTreshold,
        uint256 _comissionPercentageIn10000,
        address payable _defaultRoyaltyRecipient,
        uint256 _defaultRoyaltyPercentageIn10000,
        uint256 _presalePrice
    ) ERC721Template(
        _name,
        _symbol,
        _contractURI,
        _maxSupply,
        _publicPrice,
        _defaultBaseURI,
        _notRevealedURI,
        _comissionRecipient,
        _fixedCommisionTreshold,
        _comissionPercentageIn10000,
        _defaultRoyaltyRecipient,
        _defaultRoyaltyPercentageIn10000
    ) {
        // add code here if you want to do something specific during contract deployment
        presalePrice = _presalePrice;
    }

    // Get a root for a tier
    function getPresaleMerkleRoot(uint256 tier) public view returns (bytes32) {
        return presaleMerkleRoots[tier];
    }

    function getValidTier(address _user, bytes32[] calldata _studentProof) public view returns (uint256) {
        // if (balanceOf(_user) > 0) {
        //     return 0;
        // }

        uint256 highestValidTier = 0;
        for (uint256 i = 0; i < tiers.length; i++) {
            bytes32 root = presaleMerkleRoots[tiers[i]];
            if (MerkleProof.verify(_studentProof, root, keccak256(abi.encodePacked(_user)))) {
                // Check if the current valid tier is higher than the highestValidTier
                if (tiers[i] > highestValidTier) {
                    highestValidTier = tiers[i];
                }
            }
        }

        return highestValidTier - presaleMintedBy(msg.sender);
    }

    function presaleMintedBy(address account) public view returns (uint256) {
        return presaleMints[account];
    }

    function presaleMint(
        uint256 k,
        bytes32[] calldata _studentProof
    ) external payable {
        require(block.timestamp >= presaleStartTime, "Presale not active");
        require(msg.value >= k * presalePrice, "Insufficient funds for mint");
        uint256 ts = totalSupply();
        require(ts + k <= maxSupply, "Cannot mint more than max supply");
        uint256 validTier = getValidTier(msg.sender, _studentProof);
        // error if the user is not in any tier or if the tier is smaller than the number of tokens user wants to mint
        require(validTier > 0 && validTier >= k, "Not prelisted");
        presaleMints[msg.sender] += k;
        for (uint256 i = 1; i <= k; i++) {
            _safeMint(msg.sender, ts + i);
        }
    }

    function setPresaleMerkleRoot(uint256 tier, bytes32 _presaleMerkleRoot) external onlyOwner {
        // If the tier has not been set yet, add it to the tiers list
        if(presaleMerkleRoots[tier] == bytes32(0)) {
            tiers.push(tier);
        }
        presaleMerkleRoots[tier] = _presaleMerkleRoot;
    }

    function setPresalePrice(uint256 _newPrice) public onlyOwner {
        presalePrice = _newPrice;
    }

    function togglePresaleActive() external onlyOwner {
        if (block.timestamp < presaleStartTime) {
            presaleStartTime = block.timestamp;
        } else {
            // This effectively disables the presale sale by setting the start time to a far future
            presaleStartTime = type(uint256).max;
        }
    }

    // Sets the start time of the public sale to a specific timestamp
    function setPresaleStartTime(uint256 _presaleStartTime) external onlyOwner {
        presaleStartTime = _presaleStartTime;
    }
}