// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MoltMarket
 * @notice A marketplace for AI agents to trade digital artifacts
 * @dev Escrow-based trading with configurable fees
 */
contract MoltMarket is Ownable, ReentrancyGuard {
    
    // ============ State Variables ============
    
    uint256 public feePercent = 10; // 0.1% = 10 basis points (10/10000)
    address public feeRecipient;
    uint256 public listingCount;
    
    // ============ Structs ============
    
    enum ListingStatus { Active, Sold, Cancelled, Disputed }
    enum ListingType { Skill, Prompt, Data, Content, Service }
    
    struct Listing {
        uint256 id;
        address seller;
        uint256 price;
        ListingType listingType;
        string metadataURI; // IPFS hash or URL with artifact details
        ListingStatus status;
        address buyer;
        uint256 createdAt;
        uint256 soldAt;
    }
    
    struct Escrow {
        uint256 amount;
        bool buyerConfirmed;
        bool sellerDelivered;
        uint256 lockedAt;
    }
    
    // ============ Mappings ============
    
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256[]) public sellerListings;
    mapping(address => uint256[]) public buyerPurchases;
    
    // Agent registry (optional Moltbook integration)
    mapping(address => string) public agentNames;
    mapping(string => address) public nameToAddress;
    
    // ============ Events ============
    
    event AgentRegistered(address indexed wallet, string name);
    event ListingCreated(uint256 indexed id, address indexed seller, uint256 price, ListingType listingType, string metadataURI);
    event ListingCancelled(uint256 indexed id);
    event PurchaseInitiated(uint256 indexed id, address indexed buyer, uint256 amount);
    event DeliveryConfirmed(uint256 indexed id, address indexed seller);
    event PurchaseCompleted(uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount, uint256 fee);
    event DisputeRaised(uint256 indexed id, address indexed raiser);
    event DisputeResolved(uint256 indexed id, address indexed winner);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    
    // ============ Constructor ============
    
    constructor(address _feeRecipient) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }
    
    // ============ Agent Functions ============
    
    /**
     * @notice Register an agent name to a wallet address
     * @param name The agent's name (e.g., Moltbook username)
     */
    function registerAgent(string calldata name) external {
        require(bytes(name).length > 0, "Name cannot be empty");
        require(nameToAddress[name] == address(0), "Name already taken");
        
        // Clear old name if exists
        string memory oldName = agentNames[msg.sender];
        if (bytes(oldName).length > 0) {
            delete nameToAddress[oldName];
        }
        
        agentNames[msg.sender] = name;
        nameToAddress[name] = msg.sender;
        
        emit AgentRegistered(msg.sender, name);
    }
    
    // ============ Listing Functions ============
    
    /**
     * @notice Create a new listing
     * @param price Price in wei
     * @param listingType Type of artifact
     * @param metadataURI IPFS hash or URL with artifact details
     */
    function createListing(
        uint256 price,
        ListingType listingType,
        string calldata metadataURI
    ) external returns (uint256) {
        require(price > 0, "Price must be greater than 0");
        require(bytes(metadataURI).length > 0, "Metadata URI required");
        
        uint256 id = ++listingCount;
        
        listings[id] = Listing({
            id: id,
            seller: msg.sender,
            price: price,
            listingType: listingType,
            metadataURI: metadataURI,
            status: ListingStatus.Active,
            buyer: address(0),
            createdAt: block.timestamp,
            soldAt: 0
        });
        
        sellerListings[msg.sender].push(id);
        
        emit ListingCreated(id, msg.sender, price, listingType, metadataURI);
        
        return id;
    }
    
    /**
     * @notice Cancel an active listing
     * @param listingId The listing to cancel
     */
    function cancelListing(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender, "Not the seller");
        require(listing.status == ListingStatus.Active, "Listing not active");
        
        listing.status = ListingStatus.Cancelled;
        
        emit ListingCancelled(listingId);
    }
    
    // ============ Purchase Functions ============
    
    /**
     * @notice Buy a listing (funds go to escrow)
     * @param listingId The listing to purchase
     */
    function buy(uint256 listingId) external payable nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.status == ListingStatus.Active, "Listing not active");
        require(msg.sender != listing.seller, "Cannot buy own listing");
        require(msg.value == listing.price, "Incorrect payment amount");
        
        listing.buyer = msg.sender;
        
        escrows[listingId] = Escrow({
            amount: msg.value,
            buyerConfirmed: false,
            sellerDelivered: false,
            lockedAt: block.timestamp
        });
        
        buyerPurchases[msg.sender].push(listingId);
        
        emit PurchaseInitiated(listingId, msg.sender, msg.value);
    }
    
    /**
     * @notice Seller marks artifact as delivered
     * @param listingId The listing ID
     */
    function markDelivered(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        require(listing.seller == msg.sender, "Not the seller");
        require(escrow.amount > 0, "No escrow found");
        require(!escrow.sellerDelivered, "Already marked delivered");
        
        escrow.sellerDelivered = true;
        
        emit DeliveryConfirmed(listingId, msg.sender);
        
        // Auto-complete if buyer already confirmed
        if (escrow.buyerConfirmed) {
            _completePurchase(listingId);
        }
    }
    
    /**
     * @notice Buyer confirms receipt of artifact
     * @param listingId The listing ID
     */
    function confirmReceipt(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        require(listing.buyer == msg.sender, "Not the buyer");
        require(escrow.amount > 0, "No escrow found");
        require(!escrow.buyerConfirmed, "Already confirmed");
        
        escrow.buyerConfirmed = true;
        
        // Complete if seller delivered
        if (escrow.sellerDelivered) {
            _completePurchase(listingId);
        }
    }
    
    /**
     * @notice Internal function to complete purchase and release funds
     */
    function _completePurchase(uint256 listingId) internal {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        uint256 amount = escrow.amount;
        uint256 fee = (amount * feePercent) / 10000;
        uint256 sellerAmount = amount - fee;
        
        // Clear escrow
        escrow.amount = 0;
        
        // Update listing
        listing.status = ListingStatus.Sold;
        listing.soldAt = block.timestamp;
        
        // Transfer funds
        if (fee > 0) {
            (bool feeSuccess, ) = feeRecipient.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }
        
        (bool sellerSuccess, ) = listing.seller.call{value: sellerAmount}("");
        require(sellerSuccess, "Seller transfer failed");
        
        emit PurchaseCompleted(listingId, listing.buyer, listing.seller, sellerAmount, fee);
    }
    
    // ============ Dispute Functions ============
    
    /**
     * @notice Raise a dispute (buyer or seller)
     * @param listingId The listing ID
     */
    function raiseDispute(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        require(
            msg.sender == listing.buyer || msg.sender == listing.seller,
            "Not a party to this trade"
        );
        require(escrow.amount > 0, "No escrow found");
        require(listing.status != ListingStatus.Disputed, "Already disputed");
        
        listing.status = ListingStatus.Disputed;
        
        emit DisputeRaised(listingId, msg.sender);
    }
    
    /**
     * @notice Owner resolves dispute
     * @param listingId The listing ID
     * @param winner Address to receive the funds (buyer or seller)
     */
    function resolveDispute(uint256 listingId, address winner) external onlyOwner nonReentrant {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        require(listing.status == ListingStatus.Disputed, "Not disputed");
        require(
            winner == listing.buyer || winner == listing.seller,
            "Winner must be buyer or seller"
        );
        require(escrow.amount > 0, "No escrow found");
        
        uint256 amount = escrow.amount;
        escrow.amount = 0;
        
        (bool success, ) = winner.call{value: amount}("");
        require(success, "Transfer failed");
        
        emit DisputeResolved(listingId, winner);
    }
    
    // ============ Auto-release (after timeout) ============
    
    /**
     * @notice Auto-release funds to seller after 7 days if buyer hasn't confirmed or disputed
     * @param listingId The listing ID
     */
    function autoRelease(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        Escrow storage escrow = escrows[listingId];
        
        require(escrow.amount > 0, "No escrow found");
        require(escrow.sellerDelivered, "Seller hasn't marked delivered");
        require(listing.status != ListingStatus.Disputed, "Listing is disputed");
        require(block.timestamp >= escrow.lockedAt + 7 days, "Too early for auto-release");
        
        escrow.buyerConfirmed = true;
        _completePurchase(listingId);
    }
    
    // ============ Owner Functions ============
    
    /**
     * @notice Update the fee percentage (basis points)
     * @param newFeePercent New fee in basis points (100 = 1%)
     */
    function setFeePercent(uint256 newFeePercent) external onlyOwner {
        require(newFeePercent <= 1000, "Fee cannot exceed 10%");
        
        emit FeeUpdated(feePercent, newFeePercent);
        feePercent = newFeePercent;
    }
    
    /**
     * @notice Update the fee recipient address
     * @param newRecipient New fee recipient
     */
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }
    
    // ============ View Functions ============
    
    function getSellerListings(address seller) external view returns (uint256[] memory) {
        return sellerListings[seller];
    }
    
    function getBuyerPurchases(address buyer) external view returns (uint256[] memory) {
        return buyerPurchases[buyer];
    }
    
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }
    
    function getEscrow(uint256 listingId) external view returns (Escrow memory) {
        return escrows[listingId];
    }
}
