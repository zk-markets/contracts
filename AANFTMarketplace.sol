// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Core dependencies
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Utilities for signature validation
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IWETH.sol";

/**
 * @title AA NFT Marketplace
 * @dev A decentralized platform for trading NFTs.
 * Supports Smart Accounts and gasless-listing operations.
 */
contract AANftMarketplace is ReentrancyGuard, Ownable, Pausable {

    // State variables
    mapping (bytes32 => bool) public listingsClaimed; // Tracks if a listing has been claimed
    mapping (bytes32 => bool) public offersClaimed; // Tracks if an offer has been claimed

    uint256 public chainId;
    address public wethAddress; // State variable for storing WETH contract address
    address public premiumNftAddress;         // Address for premium NFTs
    uint256 public platformFee;         // Platform fee in basis points (e.g., 200 means 2%)
    uint256 public premiumFee = 0;            // Fee for premium holders, initially 0% (e.g., 200 means 2%)

    // Constants
    // bytes private constant ETHEREUM_SIGNED_PREFIX = "\x19Ethereum Signed Message:\n32";
    bytes4 private constant EIP1271_SUCCESS_RETURN_VALUE = 0x1626ba7e;
    uint256 private constant MAX_FEE = 10000;  // Represented in basis points for fee calculations

    // // Domain details
    string public name = "zkMarkets";
    string public version = "1";
    address public verifyingContract = address(this);
    string public constant EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

    // Events to log various activities on the contract
    event ItemBought(address indexed buyer, address indexed nftAddress, uint256 indexed tokenId, address seller, uint256 price);
    event WETHOfferAccepted(address indexed nftAddress, uint256 indexed tokenId, address indexed buyer, uint256 price);
    event ListingCanceled(address indexed seller, bytes32 indexed listingHash);
    event WETHOfferCancelled(address indexed buyer, bytes32 indexed offerHash);

    // Constructor with premiumNftAddress parameter
    constructor(address _wethAddress, address _premiumNftAddress, uint256 _platformFee, uint256 _premiumFee) Ownable(msg.sender) {
        if (_wethAddress != address(0)) {
            wethAddress = _wethAddress;
        }
        if (_premiumNftAddress != address(0)) {
            premiumNftAddress = _premiumNftAddress;
        }
        if (_platformFee > 0) {
            platformFee = _platformFee;
        }
        if (_premiumFee > 0) {
            premiumFee = _premiumFee;
        }
        chainId = block.chainid;
    }

    /**
     * @notice Allows a buyer to purchase an NFT.
     * @param _signature The signature proving authenticity of the listing.
     * @param nftAddress Address of the NFT contract.
     * @param tokenId ID of the token being sold.
     * @param timestamp Timestamp when the NFT was listed.
     * @param collectionRoyaltyIn10000 Royalty fee for the NFT collection in basis points.
     */
    function acceptListing(bytes memory _signature, address listerAddress, address nftAddress, uint256 tokenId, uint256 timestamp, uint256 collectionRoyaltyIn10000) 
        external
        payable
        nonReentrant
        whenNotPaused
    {
        bytes32 fullListingHash = createListingHash(listerAddress, nftAddress, tokenId, msg.value, timestamp, collectionRoyaltyIn10000);

        // Validate that the NFT owner is the signer of the listing
        address nftOwnerAddress = IERC721(nftAddress).ownerOf(tokenId);

        //function verifySignature(bytes32 fullHash, bytes memory _signature, address signer) public view returns (address) {
        require(verifySignature(fullListingHash, _signature, nftOwnerAddress), "Invalid signature or incorrect signer");
        
        require(!listingsClaimed[fullListingHash], "Listing already claimed");
        listingsClaimed[fullListingHash] = true;

        // // Handle the transfer of funds and NFT
        handlePayments(nftOwnerAddress, msg.value, nftAddress, collectionRoyaltyIn10000);
        IERC721(nftAddress).transferFrom(nftOwnerAddress, msg.sender, tokenId);

        emit ItemBought(msg.sender, nftAddress, tokenId, nftOwnerAddress, msg.value);
    }

    function cancelListing(bytes memory _cancelSignature, address listerAddress, address nftAddress, uint256 tokenId, uint256 timestamp, uint256 collectionRoyaltyIn10000, uint256 priceWei)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 fullListingHash = createListingHash(listerAddress, nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
        require(!listingsClaimed[fullListingHash], "Listing already claimed");

        // sender should be lister
        require(listerAddress == msg.sender, "Only lister can cancel listing");


        bytes32 fullCancelHash = createCancelListingHash(listerAddress, nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
        // Validate the cancellation request
        require(verifySignature(fullCancelHash, _cancelSignature, listerAddress), "Invalid signature or incorrect signer");
        
        listingsClaimed[fullListingHash] = true;
        emit ListingCanceled(listerAddress, fullListingHash);
    }
    
    function createListingHashCommon(string memory messageType, address listerAddress, address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) private view returns (bytes32) {
        string memory baseMessageType = "(address listerAddress,address nftAddress,uint256 tokenId,uint256 priceWei,uint256 timestamp,uint256 collectionRoyaltyIn10000)";
        string memory fullMessageType = string(abi.encodePacked(messageType, baseMessageType));

        return getFullHash(keccak256(
            abi.encode(
                keccak256(abi.encodePacked(fullMessageType)),
                listerAddress,
                nftAddress,
                tokenId,
                priceWei,
                timestamp,
                collectionRoyaltyIn10000
            )
        ));
    }

    function createListingHash(address listerAddress, address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) public view returns (bytes32) {
        return createListingHashCommon("Listing", listerAddress, nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
    }

    function createCancelListingHash(address listerAddress, address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) public view returns (bytes32) {
        return createListingHashCommon("CancelListing", listerAddress, nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
    }

    function acceptWETHOffer(bytes memory _signature, address nftAddress, uint256 tokenId, uint256 timestamp, uint256 collectionRoyaltyIn10000, uint256 priceWei, address buyer)
        external
        nonReentrant
        whenNotPaused
    {
        // Validate that the NFT owner is the signer of the listing
        address nftOwnerAddress = IERC721(nftAddress).ownerOf(tokenId);
        // make sure owner is caller
        require(nftOwnerAddress == msg.sender, "Only owner can accept offer");

        bytes32 fullOfferHash = createWETHOfferHash(nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);

        //function verifySignature(bytes32 fullHash, bytes memory _signature, address signer) public view returns (address) {
        require(verifySignature(fullOfferHash, _signature, buyer), "Invalid signature or incorrect signer");
        
        require(!offersClaimed[fullOfferHash], "Offer already claimed");
        offersClaimed[fullOfferHash] = true;

        // Handle the transfer of NFT and funds
        IERC721(nftAddress).transferFrom(nftOwnerAddress, buyer, tokenId);

        // Transfer WETH to the seller and make sure he receives it
        require(IWETH(wethAddress).transferFrom(buyer, nftOwnerAddress, priceWei), "WETH transfer failed");


        emit WETHOfferAccepted(nftAddress, tokenId, msg.sender, priceWei);
    }

    function cancelWETHOffer(bytes memory _cancelSignature, address nftAddress, uint256 tokenId, uint256 timestamp, uint256 collectionRoyaltyIn10000, uint256 priceWei, address buyer)
        external
        nonReentrant
        whenNotPaused
    {
        bytes32 fullOfferHash = createWETHOfferHash(nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
        require(!offersClaimed[fullOfferHash], "Offer already claimed");

        // sender should be offer maker
        require(buyer == msg.sender, "Only offer maker can cancel offer");

        bytes32 fullCancelHash = createWETHCancelOfferHash(nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
        
        // Validate the cancellation request
        require(verifySignature(fullCancelHash, _cancelSignature, buyer), "Invalid signature or incorrect signer");
        
        offersClaimed[fullOfferHash] = true;
        emit WETHOfferCancelled(buyer, fullOfferHash);
    }

    function createWETHOfferHashCommon(string memory action, address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) private view returns (bytes32) {
        string memory baseMessageType = "(address nftAddress,uint256 tokenId,uint256 priceWei,uint256 timestamp,uint256 collectionRoyaltyIn10000)";
        string memory fullMessageType = string(abi.encodePacked(action, baseMessageType));

        return getFullHash(keccak256(
            abi.encode(
                keccak256(abi.encodePacked(fullMessageType)),
                nftAddress,
                tokenId,
                priceWei,
                timestamp,
                collectionRoyaltyIn10000
            )
        ));
    }

    function createWETHOfferHash(address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) public view returns (bytes32) {
        return createWETHOfferHashCommon("Offer", nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
    }

    function createWETHCancelOfferHash(address nftAddress, uint256 tokenId, uint256 priceWei, uint256 timestamp, uint256 collectionRoyaltyIn10000) public view returns (bytes32) {
        return createWETHOfferHashCommon("CancelOffer", nftAddress, tokenId, priceWei, timestamp, collectionRoyaltyIn10000);
    }

    /**
     * @notice Distributes payments for a sold NFT.
     * @dev This includes fees for the platform, royalties, and the seller's proceeds.
     * @param seller The address of the NFT seller.
     * @param totalPrice The total price the NFT was sold for.
     * @param nftCollection Address of the NFT's contract.
     * @param collectionRoyaltyIn10000 The royalty fee for the NFT collection in basis points.
     */
    function handlePayments(address seller, uint256 totalPrice, address nftCollection, uint256 collectionRoyaltyIn10000) internal {
        uint256 platformCut;
        uint256 collectionOwnerCut;

        // Calculate the platform's cut. Reduced for premium sellers.
        uint256 effectivePlatformFee = (premiumNftAddress != address(0) && isPremiumHolder(seller)) ? premiumFee : platformFee;
        if(effectivePlatformFee > 0) {
            platformCut = (effectivePlatformFee * totalPrice) / 10000;
        }

        // Calculate royalty for the NFT collection.
        if(collectionRoyaltyIn10000 > 0) {
            collectionOwnerCut = (collectionRoyaltyIn10000 * totalPrice) / 10000;
            (bool collectionSuccess,) = payable(Ownable(nftCollection).owner()).call{value: collectionOwnerCut}("");
            require(collectionSuccess, "Collection owner transfer failed");
        }

        // Remaining amount is transferred to the seller.
        uint256 sellerCut = totalPrice - collectionOwnerCut - platformCut;
        (bool sellerSuccess,) = payable(seller).call{value: sellerCut}("");
        require(sellerSuccess, "Seller transfer failed");
    }

    function setWETHAddress(address _wethAddress) external onlyOwner {
        wethAddress = _wethAddress;
    }

    /*
        Internal helper functions
    */

    /**
     * @notice Check if a given user holds a premium NFT.
     * @param user The address of the user to check.
     * @return true if the user holds a premium NFT, false otherwise.
     */
    function isPremiumHolder(address user) internal view returns (bool) {
        IERC721 premiumNft = IERC721(premiumNftAddress);
        return premiumNft.balanceOf(user) > 0;
    }

    /**
     * @notice Checks if an address is a deployed contract.
     * @param account Address to check.
     * @return true if the address is a contract, false otherwise.
     */
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    function verifySignature(bytes32 fullHash, bytes memory _signature, address signer) public view returns (bool) {
        // For contract accounts, we use EIP-1271's isValidSignature.
        if (isContract(signer)) {
            bytes4 magicValue = IERC1271(signer).isValidSignature(fullHash, _signature);
            return magicValue == EIP1271_SUCCESS_RETURN_VALUE;
        }

        address recoveredSigner = ECDSA.recover(fullHash, _signature);

        if (recoveredSigner == signer) {
            return true;
        }
        return false;
    }

    function getSignerAddress(bytes32 fullHash, bytes memory _signature) public view returns (address) {
        return ECDSA.recover(fullHash, _signature);
    }

    function domain() external view returns (string memory name_, string memory version_, uint256 chainId_, address verifyingContract_) {
        name_ = name;
        version_ = version;
        chainId_ = chainId;
        verifyingContract_ = verifyingContract;
    }

    function getDomainSeparator() public view returns (bytes32) {
        // Return the domain separator
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(EIP712_DOMAIN_TYPE)),
                keccak256(abi.encodePacked(name)),
                keccak256(abi.encodePacked(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function getFullHash(bytes32 _hash) public view returns (bytes32) {
        bytes32 fullHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                _hash
            )
        );
        return fullHash;
    }

    /**
     * @notice Checks if the contract supports Smart Accounts aka. EIP1271
     * @return Always returns true.
     */
    function EIP1271Compatible() external pure returns (bool) {
        return true;
    }

    /*
     * Administrative functions
    */

    /**
     * @notice Allows the platform owner to update the platform fee.
     * @param newPlatformFee The new fee (in basis points).
     */
    function updatePlatformFee(uint256 newPlatformFee) external onlyOwner {
        require(newPlatformFee < MAX_FEE, "Platform fee out of bounds");
        platformFee = newPlatformFee;
    }

    /**
     * @notice Allows the platform owner to update the fee for premium holders.
     * @param newPremiumFee The new fee (in basis points).
     */
    function updatePremiumFee(uint256 newPremiumFee) external onlyOwner {
        require(newPremiumFee < MAX_FEE, "Premium fee out of bounds");
        premiumFee = newPremiumFee;
    }

    /**
     * @notice Allows the platform owner to update the address for premium NFTs.
     * @param newPremiumNftAddress The new premium NFT address.
     */
    function updatePremiumNftAddress(address newPremiumNftAddress) external onlyOwner {
        premiumNftAddress = newPremiumNftAddress;
    }

    /**
    * @notice Pauses the marketplace, preventing sales.
    */
    function pauseMarketplace() external onlyOwner {
        _pause();
    }

    /**
    * @notice Unpauses the marketplace, allowing sales.
    */
    function unpauseMarketplace() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Allows the platform owner to withdraw accumulated funds.
     */
    function withdrawAll() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        payable(owner()).transfer(balance);
    }
}