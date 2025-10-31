// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title NovaAssetVault
/// @notice Enhanced vault that works with asset classes and multi-asset NAV oracle
/// @dev Extends NovaVault4626 to support asset class identification for multi-asset systems

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20 as IERC20Base} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {FeeModule} from "./FeeModule.sol";
import {MultiAssetNavOracle} from "./MultiAssetNavOracle.sol";
import {INovaTreasury} from "./interfaces/INovaTreasury.sol";

contract NovaAssetVault is Initializable, ERC4626Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20Base;

    /// @notice Emitted when asset class is set
    event AssetClassSet(bytes32 indexed assetClass, string name);

    /// @notice Emitted when a new tranche is created
    event TrancheCreated(address indexed owner, uint256 shares, uint256 unlockAt);
    /// @notice Emitted when a redemption request is queued for early exit
    event EarlyExitRequested(address indexed owner, uint256 shares, uint256 penalty, uint256 unlockAt);
    /// @notice Emitted when an early exit request is queued for D+1 settlement
    event RedemptionQueued(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 penalty,
        uint256 settlementDate
    );
    /// @notice Emitted when a queued redemption is processed by an operator
    event RedemptionProcessed(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 sharesRedeemed,
        uint256 assetsReceived,
        uint256 penaltyPaid
    );
    /// @notice Emitted when a queued redemption is cancelled
    event RedemptionCancelled(uint256 indexed requestId, address indexed owner, uint256 shares);

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant COMPLIANCE_ADMIN_ROLE = keccak256("COMPLIANCE_ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant ASSET_CLASS_MANAGER_ROLE = keccak256("ASSET_CLASS_MANAGER_ROLE");

    struct Tranche {
        uint256 shares;
        uint64 unlockAt;
    }

    /// @notice Structure for queued redemption requests
    struct RedemptionRequest {
        address owner; // Owner of the shares
        address receiver; // Address to receive the assets
        uint256 shares; // Number of shares to redeem
        uint256 penalty; // Penalty amount in assets
        uint256 requestTime; // When the request was made
        uint256 settlementDate; // Target settlement date (D+1)
        bool isProcessed; // Whether the request has been processed
        bool isCancelled; // Whether the request has been cancelled
    }

    // account => array of tranches
    mapping(address => Tranche[]) public tranches;

    // Redemption queue management
    mapping(uint256 => RedemptionRequest) public redemptionRequests;
    mapping(address => uint256[]) public userRedemptionRequests; // user => request IDs
    uint256 public nextRequestId;
    uint256 public constant SETTLEMENT_DELAY = 1 days; // D+1 settlement

    /// @notice Asset class identifier for this vault
    bytes32 public assetClass;

    ComplianceRegistry public compliance;
    FeeModule public feeModule;
    MultiAssetNavOracle public navOracle;

    /// @notice Treasury contract where idle assets can be sent for off‑chain business operations
    INovaTreasury public treasury;

    // Default lock duration in seconds (e.g. 30 days)
    uint64 public constant DEFAULT_LOCK_DURATION = 30 days;

    bool public paused;
    bool public transfersRestricted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the multi-asset vault
     * @param asset_ The underlying asset
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param admin Admin address
     * @param complianceRegistry Compliance registry address
     * @param feeModuleAddress Fee module address
     * @param navOracleAddress Multi-asset NAV oracle address
     * @param _assetClass Asset class identifier for this vault
     */
    function initialize(
        IERC20Base asset_,
        string memory name_,
        string memory symbol_,
        address admin,
        address complianceRegistry,
        address feeModuleAddress,
        address navOracleAddress,
        bytes32 _assetClass
    ) public initializer {
        require(admin != address(0), "NovaAssetVault: zero admin address");
        require(complianceRegistry != address(0), "NovaAssetVault: zero compliance address");
        require(_assetClass != bytes32(0), "NovaAssetVault: zero asset class");

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURY_ROLE, admin);
        _grantRole(COMPLIANCE_ADMIN_ROLE, admin);
        _grantRole(ASSET_CLASS_MANAGER_ROLE, admin);

        compliance = ComplianceRegistry(complianceRegistry);
        feeModule = FeeModule(feeModuleAddress);
        navOracle = MultiAssetNavOracle(navOracleAddress);
        assetClass = _assetClass;
        transfersRestricted = true; // Default to restricted for security
        nextRequestId = 1; // Start request IDs from 1

        emit AssetClassSet(_assetClass, name_);
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    modifier onlyEligible(address sender, address receiver) {
        require(compliance.isEligibleForAssetClass(assetClass, sender), "sender not eligible");
        require(compliance.isEligibleForAssetClass(assetClass, receiver), "receiver not eligible");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    /// @notice Event emitted when assets are transferred to the treasury
    event TreasuryTransfer(address indexed treasury, uint256 amount);

    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        paused = false;
    }

    /// @notice Update the asset class (admin only)
    function setAssetClass(bytes32 _assetClass) external onlyRole(ASSET_CLASS_MANAGER_ROLE) {
        require(_assetClass != bytes32(0), "zero asset class");
        assetClass = _assetClass;
        emit AssetClassSet(_assetClass, name());
    }

    /// @notice Update the compliance registry address
    function setComplianceRegistry(address newRegistry) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        require(newRegistry != address(0), "zero address");
        compliance = ComplianceRegistry(newRegistry);
    }

    /// @notice Set whether transfers are restricted
    function setTransfersRestricted(bool restricted) external onlyRole(COMPLIANCE_ADMIN_ROLE) {
        transfersRestricted = restricted;
    }

    /// @notice Calculate next settlement date (D+1)
    /// @param fromDate Starting date
    /// @return Next day timestamp for settlement
    function getNextSettlementDate(uint256 fromDate) public pure returns (uint256) {
        return fromDate + SETTLEMENT_DELAY;
    }

    /// @notice Set the treasury contract
    /// @dev Only accounts with the TREASURY_ROLE may call this function
    function setTreasury(address _treasury) external onlyRole(TREASURY_ROLE) {
        require(_treasury != address(0), "zero address");
        treasury = INovaTreasury(_treasury);
    }

    /// @notice Transfer idle assets to the treasury for off‑chain business operations
    /// @param amount Amount of underlying asset to transfer
    /// @dev Only callable by accounts with the TREASURY_ROLE.  The caller is
    ///      responsible for updating the NAV via NavOracle after external use of
    ///      these assets so that share values remain accurate.
    function transferToTreasury(uint256 amount) external onlyRole(TREASURY_ROLE) whenNotPaused {
        _transferIdleToTreasury(amount);
    }

    function _transferIdleToTreasury(uint256 amount) internal {
        require(address(treasury) != address(0), "treasury not set");
        // Check vault has enough idle assets (not locked in strategy) for transfer
        uint256 idle = IERC20Base(asset()).balanceOf(address(this));
        require(idle >= amount, "insufficient idle assets");
        // Ensure the treasury address is eligible
        require(compliance.isEligibleForAssetClass(assetClass, address(treasury)), "treasury not eligible");

        // Approve treasury to spend the tokens
        IERC20Base(asset()).approve(address(treasury), amount);

        // Call treasury's receiveAssets function
        treasury.receiveAssets(amount, "Vault asset transfer");

        emit TreasuryTransfer(address(treasury), amount);
    }

    /// @notice Deposit assets into the vault and mint shares for receiver
    /// @dev Applies a default lockup period to the created shares
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        onlyEligible(msg.sender, receiver)
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
        // record a tranche with the minted shares and unlock time
        uint64 unlockAt = uint64(block.timestamp + DEFAULT_LOCK_DURATION);
        tranches[receiver].push(Tranche({shares: shares, unlockAt: unlockAt}));
        emit TrancheCreated(receiver, shares, unlockAt);
        if (assets > 0 && address(treasury) != address(0)) {
            _transferIdleToTreasury(assets);
        }
    }

    /// @notice Redeem shares for assets after the lock period has passed
    /// @dev This override checks the earliest tranche unlock time and reverts if not yet unlocked
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        onlyEligible(msg.sender, receiver)
        returns (uint256 assets)
    {
        // find total unlocked shares for the owner
        uint256 unlockedShares = _consumeUnlockedTranches(owner, shares);
        require(unlockedShares == shares, "not enough unlocked shares");
        assets = super.redeem(shares, receiver, owner);
    }

    /// @notice Queue an early exit request for D+1 settlement
    /// @dev Queues the redemption for settlement on the next business day by an operator
    /// @param shares Number of shares to redeem early
    /// @param receiver Address to receive the assets after settlement
    /// @param owner Owner of the shares (for allowance-based redemptions)
    /// @return requestId The ID of the queued redemption request
    function queueEarlyRedemption(uint256 shares, address receiver, address owner)
        public
        whenNotPaused
        onlyEligible(msg.sender, receiver)
        returns (uint256 requestId)
    {
        require(shares > 0, "zero shares");

        // Verify ownership/allowance
        if (owner != msg.sender) {
            uint256 allowed = allowance(owner, msg.sender);
            require(allowed >= shares, "insufficient allowance");
            _approve(owner, msg.sender, allowed - shares);
        }

        // Consume shares from owner's tranches regardless of unlock time
        _consumeTranches(owner, shares);

        // Calculate penalty using asset-class-specific fee module
        uint256 assets = previewRedeem(shares);
        uint256 penaltyAssets = feeModule.computePenaltyForAssetClass(assetClass, assets);
        require(assets > penaltyAssets, "penalty exceeds assets");

        // Calculate settlement date (D+1)
        uint256 settlementDate = getNextSettlementDate(block.timestamp);

        // Create redemption request
        requestId = nextRequestId++;
        redemptionRequests[requestId] = RedemptionRequest({
            owner: owner,
            receiver: receiver,
            shares: shares,
            penalty: penaltyAssets,
            requestTime: block.timestamp,
            settlementDate: settlementDate,
            isProcessed: false,
            isCancelled: false
        });

        // Track user's requests
        userRedemptionRequests[owner].push(requestId);

        // Burn the shares (they're committed to redemption)
        _burn(owner, shares);

        emit RedemptionQueued(requestId, owner, receiver, shares, penaltyAssets, settlementDate);

        return requestId;
    }

    /// @notice Process a queued redemption request (operators only)
    /// @dev Can only be called by operators on or after the settlement date
    /// @param requestId The ID of the request to process
    function processRedemption(uint256 requestId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        RedemptionRequest storage request = redemptionRequests[requestId];

        require(!request.isProcessed, "already processed");
        require(!request.isCancelled, "request cancelled");
        require(block.timestamp >= request.settlementDate, "settlement date not reached");
        require(request.shares > 0, "invalid request");

        // Calculate assets to transfer
        uint256 grossAssets = previewRedeem(request.shares);
        uint256 netAssets = grossAssets - request.penalty;

        // Ensure vault has sufficient assets
        uint256 vaultBalance = IERC20Base(asset()).balanceOf(address(this));
        require(vaultBalance >= grossAssets, "insufficient vault assets");

        // Mark as processed
        request.isProcessed = true;

        // Transfer net assets to receiver
        if (netAssets > 0) {
            IERC20Base(asset()).safeTransfer(request.receiver, netAssets);
        }

        // Transfer penalty to penalty recipient (asset-class-specific)
        if (request.penalty > 0) {
            (, , address penaltyRecip) = feeModule.getRecipientsForAssetClass(assetClass);
            IERC20Base(asset()).safeTransfer(penaltyRecip, request.penalty);
        }

        emit RedemptionProcessed(requestId, request.owner, request.receiver, request.shares, netAssets, request.penalty);
    }

    /// @notice Cancel a queued redemption request (owner only, before processing)
    /// @dev Returns the shares to the owner if not yet processed
    /// @param requestId The ID of the request to cancel
    function cancelRedemption(uint256 requestId) external whenNotPaused {
        RedemptionRequest storage request = redemptionRequests[requestId];

        require(request.owner == msg.sender, "not request owner");
        require(!request.isProcessed, "already processed");
        require(!request.isCancelled, "already cancelled");

        // Mark as cancelled
        request.isCancelled = true;

        // Return shares to owner
        _mint(request.owner, request.shares);

        emit RedemptionCancelled(requestId, request.owner, request.shares);
    }

    /// @notice Consume unlocked tranches for a given amount of shares
    /// @dev Returns the total shares consumed; reverts if not enough unlocked shares
    function _consumeUnlockedTranches(address owner, uint256 sharesNeeded) internal returns (uint256) {
        uint256 consumed;
        Tranche[] storage userTranches = tranches[owner];
        uint256 len = userTranches.length;
        for (uint256 i = 0; i < len && consumed < sharesNeeded; i++) {
            Tranche storage t = userTranches[i];
            if (t.unlockAt <= block.timestamp && t.shares > 0) {
                uint256 take = sharesNeeded - consumed;
                if (t.shares <= take) {
                    take = t.shares;
                }
                t.shares -= take;
                consumed += take;
            }
        }
        return consumed;
    }

    /// @notice Consume tranches regardless of unlock time (used for early exit)
    function _consumeTranches(address owner, uint256 sharesNeeded) internal {
        uint256 consumed;
        Tranche[] storage userTranches = tranches[owner];
        uint256 len = userTranches.length;
        for (uint256 i = 0; i < len && consumed < sharesNeeded; i++) {
            Tranche storage t = userTranches[i];
            if (t.shares > 0) {
                uint256 take = sharesNeeded - consumed;
                if (t.shares <= take) {
                    take = t.shares;
                }
                t.shares -= take;
                consumed += take;
            }
        }
        require(consumed == sharesNeeded, "not enough shares");
    }

    /// @notice Get all redemption request IDs for a user
    /// @param user Address of the user
    /// @return Array of request IDs
    function getUserRedemptionRequests(address user) external view returns (uint256[] memory) {
        return userRedemptionRequests[user];
    }

    /// @notice Get detailed information about a redemption request
    /// @param requestId The ID of the request
    /// @return The complete RedemptionRequest struct
    function getRedemptionRequest(uint256 requestId) external view returns (RedemptionRequest memory) {
        return redemptionRequests[requestId];
    }

    /// @notice Get pending redemption requests that can be processed
    /// @return Array of request IDs ready for settlement
    function getPendingRedemptions() external view returns (uint256[] memory) {
        uint256[] memory pendingIds = new uint256[](nextRequestId - 1);
        uint256 count = 0;

        for (uint256 i = 1; i < nextRequestId; i++) {
            RedemptionRequest storage request = redemptionRequests[i];
            if (!request.isProcessed && !request.isCancelled && block.timestamp >= request.settlementDate) {
                pendingIds[count] = i;
                count++;
            }
        }

        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = pendingIds[i];
        }

        return result;
    }

    /// @notice Batch process multiple redemption requests
    /// @param requestIds Array of request IDs to process
    function batchProcessRedemptions(uint256[] calldata requestIds) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        for (uint256 i = 0; i < requestIds.length; i++) {
            // Call internal version to avoid repeated role checks
            _processRedemptionInternal(requestIds[i]);
        }
    }

    /// @notice Internal function for processing redemptions (no role check)
    function _processRedemptionInternal(uint256 requestId) internal {
        RedemptionRequest storage request = redemptionRequests[requestId];

        if (
            request.isProcessed || request.isCancelled || block.timestamp < request.settlementDate
                || request.shares == 0
        ) {
            return; // Skip invalid/processed requests
        }

        // Calculate assets to transfer
        uint256 grossAssets = previewRedeem(request.shares);
        uint256 netAssets = grossAssets - request.penalty;

        // Check if vault has sufficient assets
        uint256 vaultBalance = IERC20Base(asset()).balanceOf(address(this));
        if (vaultBalance < grossAssets) {
            return; // Skip if insufficient funds
        }

        // Mark as processed
        request.isProcessed = true;

        // Transfer net assets to receiver
        if (netAssets > 0) {
            IERC20Base(asset()).safeTransfer(request.receiver, netAssets);
        }

        // Transfer penalty to penalty recipient (asset-class-specific)
        if (request.penalty > 0) {
            (, , address penaltyRecip) = feeModule.getRecipientsForAssetClass(assetClass);
            IERC20Base(asset()).safeTransfer(penaltyRecip, request.penalty);
        }

        emit RedemptionProcessed(requestId, request.owner, request.receiver, request.shares, netAssets, request.penalty);
    }

    /// @notice Override totalAssets to use the multi-asset NAV oracle
    function totalAssets() public view override returns (uint256) {
        // Use the asset class specific NAV from the multi-asset oracle
        (uint256 nav,) = navOracle.getNav(assetClass);
        return nav;
    }

    /// @notice Get asset class information
    /// @return assetClass Asset class identifier
    /// @return name Asset class name from oracle
    /// @return nav Current NAV
    /// @return isActive Whether asset class is active
    function getAssetClassInfo() external view returns (bytes32, string memory name, uint256 nav, bool isActive) {
        (name,, isActive, nav,) = navOracle.getAssetClassInfo(assetClass);
        return (assetClass, name, nav, isActive);
    }

    /// @dev Override the ERC20 _update hook to enforce compliance on share transfers
    /// @notice This ensures all share transfers comply with regulations and restrictions
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        // Skip compliance checks for minting/burning (vault operations)
        if (from == address(0) || to == address(0)) {
            return;
        }

        // If transfers are restricted, only allow through vault operations
        if (transfersRestricted) {
            // Allow transfers if initiated by addresses with OPERATOR_ROLE (vault operations)
            require(hasRole(OPERATOR_ROLE, _msgSender()), "transfers disabled");
        }

        // Always check compliance for transfers between users
        require(compliance.isTransferAllowedForAssetClass(assetClass, from, to, amount), "transfer not allowed");
    }
}
