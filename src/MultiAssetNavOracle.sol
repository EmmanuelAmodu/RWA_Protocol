// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title MultiAssetNavOracle
 * @notice Central oracle for managing NAV (Net Asset Value) for multiple asset classes
 * @dev Extends the original NavOracle to support multiple asset classes identified by bytes32 keys
 *      Each asset class can have its own NAV, pricing data, and authorized updaters
 */
contract MultiAssetNavOracle is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    /// @notice Event emitted when NAV is updated for an asset class
    event NavUpdated(
        bytes32 indexed assetClass,
        uint256 indexed newNav,
        uint256 indexed previousNav,
        address updater,
        uint256 timestamp
    );

    /// @notice Event emitted when price feed is updated for an asset class
    event PriceFeedUpdated(
        bytes32 indexed assetClass,
        uint256 indexed newPrice,
        uint256 indexed previousPrice,
        address updater,
        uint256 timestamp
    );

    /// @notice Event emitted when change threshold is updated for an asset class
    event ChangeThresholdUpdated(bytes32 indexed assetClass, uint256 newThreshold, uint256 previousThreshold);

    /// @notice Event emitted when staleness threshold is updated for an asset class
    event StalenessThresholdUpdated(bytes32 indexed assetClass, uint256 newThreshold, uint256 previousThreshold);

    /// @notice Event emitted when asset class is registered
    event AssetClassRegistered(bytes32 indexed assetClass, string name, address indexed registry);

    /// @notice Event emitted when asset class status is updated
    event AssetClassStatusUpdated(bytes32 indexed assetClass, bool active);

    /// @notice Role that can update NAV for any asset class
    bytes32 public constant GLOBAL_ORACLE_UPDATER_ROLE = keccak256("GLOBAL_ORACLE_UPDATER_ROLE");

    /// @notice Role that can register new asset classes
    bytes32 public constant ASSET_CLASS_MANAGER_ROLE = keccak256("ASSET_CLASS_MANAGER_ROLE");

    /// @notice Structure to hold NAV data for an asset class
    struct AssetClassData {
        uint256 nav; // Current NAV
        uint256 lastUpdated; // Timestamp of last NAV update
        uint256 changeThreshold; // Maximum allowed percentage change (basis points)
        uint256 stalenessThreshold; // Maximum time before data is considered stale
        uint256 priceFeed; // External price feed value
        uint256 priceLastUpdated; // Timestamp of last price update
        bool active; // Whether this asset class is active
        string name; // Human readable name
        address registry; // Associated registry/vault address
        mapping(address => bool) authorizedUpdaters; // Asset-specific updaters
    }

    /// @notice Mapping from asset class ID to its data
    mapping(bytes32 => AssetClassData) public assetClasses;

    /// @notice Array of all registered asset class IDs for enumeration
    bytes32[] public assetClassIds;

    /// @notice Mapping to check if asset class exists
    mapping(bytes32 => bool) public assetClassExists;

    /// @notice Default values for new asset classes
    uint256 public constant DEFAULT_CHANGE_THRESHOLD = 1000; // 10%
    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 24 hours;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the multi-asset NAV oracle
     * @param admin Address to receive admin role
     */
    function initialize(address admin) public initializer {
        require(admin != address(0), "MultiAssetNavOracle: zero admin address");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GLOBAL_ORACLE_UPDATER_ROLE, admin);
        _grantRole(ASSET_CLASS_MANAGER_ROLE, admin);
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Register a new asset class
     * @param assetClass Unique identifier for the asset class
     * @param name Human readable name
     * @param registry Associated registry/vault address
     * @param initialNav Initial NAV value
     */
    function registerAssetClass(bytes32 assetClass, string memory name, address registry, uint256 initialNav)
        external
        onlyRole(ASSET_CLASS_MANAGER_ROLE)
    {
        require(!assetClassExists[assetClass], "asset class already exists");
        require(bytes(name).length > 0, "empty name");
        require(initialNav > 0, "invalid initial NAV");

        // Initialize asset class data
        AssetClassData storage data = assetClasses[assetClass];
        data.nav = initialNav;
        data.lastUpdated = block.timestamp;
        data.changeThreshold = DEFAULT_CHANGE_THRESHOLD;
        data.stalenessThreshold = DEFAULT_STALENESS_THRESHOLD;
        data.active = true;
        data.name = name;
        data.registry = registry;

        // Track existence
        assetClassExists[assetClass] = true;
        assetClassIds.push(assetClass);

        emit AssetClassRegistered(assetClass, name, registry);
        emit NavUpdated(assetClass, initialNav, 0, msg.sender, block.timestamp);
    }

    /**
     * @notice Update NAV for a specific asset class
     * @param assetClass Asset class identifier
     * @param newNav New NAV value
     */
    function updateNav(bytes32 assetClass, uint256 newNav) external {
        require(assetClassExists[assetClass], "asset class not found");
        require(newNav > 0, "invalid NAV");

        // Check authorization
        AssetClassData storage data = assetClasses[assetClass];
        require(
            hasRole(GLOBAL_ORACLE_UPDATER_ROLE, msg.sender) || data.authorizedUpdaters[msg.sender],
            "not authorized for this asset class"
        );

        require(data.active, "asset class inactive");

        uint256 previousNav = data.nav;

        // Check change threshold
        if (previousNav > 0) {
            uint256 changePercent = _calculateChangePercent(previousNav, newNav);
            require(changePercent <= data.changeThreshold, "change exceeds threshold");
        }

        // Update NAV
        data.nav = newNav;
        data.lastUpdated = block.timestamp;

        emit NavUpdated(assetClass, newNav, previousNav, msg.sender, block.timestamp);
    }

    /**
     * @notice Update price feed for a specific asset class
     * @param assetClass Asset class identifier
     * @param newPrice New price value
     */
    function updatePriceFeed(bytes32 assetClass, uint256 newPrice) external {
        require(assetClassExists[assetClass], "asset class not found");
        require(newPrice > 0, "invalid price");

        AssetClassData storage data = assetClasses[assetClass];
        require(
            hasRole(GLOBAL_ORACLE_UPDATER_ROLE, msg.sender) || data.authorizedUpdaters[msg.sender],
            "not authorized for this asset class"
        );

        require(data.active, "asset class inactive");

        uint256 previousPrice = data.priceFeed;
        data.priceFeed = newPrice;
        data.priceLastUpdated = block.timestamp;

        emit PriceFeedUpdated(assetClass, newPrice, previousPrice, msg.sender, block.timestamp);
    }

    /**
     * @notice Get NAV and last update timestamp for an asset class
     * @param assetClass Asset class identifier
     * @return nav Current NAV value
     * @return lastUpdated Timestamp of last update
     */
    function getNav(bytes32 assetClass) external view returns (uint256 nav, uint256 lastUpdated) {
        require(assetClassExists[assetClass], "asset class not found");
        AssetClassData storage data = assetClasses[assetClass];
        return (data.nav, data.lastUpdated);
    }

    /**
     * @notice Get price feed and last update timestamp for an asset class
     * @param assetClass Asset class identifier
     * @return price Current price feed value
     * @return lastUpdated Timestamp of last update
     */
    function getPriceFeed(bytes32 assetClass) external view returns (uint256 price, uint256 lastUpdated) {
        require(assetClassExists[assetClass], "asset class not found");
        AssetClassData storage data = assetClasses[assetClass];
        return (data.priceFeed, data.priceLastUpdated);
    }

    /**
     * @notice Check if NAV data is fresh for an asset class
     * @param assetClass Asset class identifier
     * @return True if data is within staleness threshold
     */
    function isNavFresh(bytes32 assetClass) external view returns (bool) {
        require(assetClassExists[assetClass], "asset class not found");
        AssetClassData storage data = assetClasses[assetClass];
        return (block.timestamp - data.lastUpdated) <= data.stalenessThreshold;
    }

    /**
     * @notice Set change threshold for an asset class
     * @param assetClass Asset class identifier
     * @param threshold New threshold in basis points
     */
    function setChangeThreshold(bytes32 assetClass, uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(assetClassExists[assetClass], "asset class not found");
        require(threshold <= 10000, "threshold too high"); // Max 100%

        AssetClassData storage data = assetClasses[assetClass];
        uint256 previous = data.changeThreshold;
        data.changeThreshold = threshold;

        emit ChangeThresholdUpdated(assetClass, threshold, previous);
    }

    /**
     * @notice Set staleness threshold for an asset class
     * @param assetClass Asset class identifier
     * @param threshold New threshold in seconds
     */
    function setStalenessThreshold(bytes32 assetClass, uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(assetClassExists[assetClass], "asset class not found");
        require(threshold > 0, "invalid threshold");

        AssetClassData storage data = assetClasses[assetClass];
        uint256 previous = data.stalenessThreshold;
        data.stalenessThreshold = threshold;

        emit StalenessThresholdUpdated(assetClass, threshold, previous);
    }

    /**
     * @notice Grant updater role for a specific asset class
     * @param assetClass Asset class identifier
     * @param updater Address to grant updater role
     */
    function grantAssetClassUpdater(bytes32 assetClass, address updater) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(assetClassExists[assetClass], "asset class not found");
        require(updater != address(0), "zero address");

        assetClasses[assetClass].authorizedUpdaters[updater] = true;
    }

    /**
     * @notice Revoke updater role for a specific asset class
     * @param assetClass Asset class identifier
     * @param updater Address to revoke updater role
     */
    function revokeAssetClassUpdater(bytes32 assetClass, address updater) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(assetClassExists[assetClass], "asset class not found");

        assetClasses[assetClass].authorizedUpdaters[updater] = false;
    }

    /**
     * @notice Check if address is authorized to update specific asset class
     * @param assetClass Asset class identifier
     * @param updater Address to check
     * @return True if authorized
     */
    function isAuthorizedUpdater(bytes32 assetClass, address updater) external view returns (bool) {
        if (!assetClassExists[assetClass]) return false;
        return hasRole(GLOBAL_ORACLE_UPDATER_ROLE, updater) || assetClasses[assetClass].authorizedUpdaters[updater];
    }

    /**
     * @notice Set active status for an asset class
     * @param assetClass Asset class identifier
     * @param active New active status
     */
    function setAssetClassActive(bytes32 assetClass, bool active) external onlyRole(ASSET_CLASS_MANAGER_ROLE) {
        require(assetClassExists[assetClass], "asset class not found");

        assetClasses[assetClass].active = active;
        emit AssetClassStatusUpdated(assetClass, active);
    }

    /**
     * @notice Get asset class information
     * @param assetClass Asset class identifier
     * @return name Human readable name
     * @return registry Associated registry address
     * @return active Whether asset class is active
     * @return nav Current NAV
     * @return lastUpdated Last update timestamp
     */
    function getAssetClassInfo(bytes32 assetClass)
        external
        view
        returns (string memory name, address registry, bool active, uint256 nav, uint256 lastUpdated)
    {
        require(assetClassExists[assetClass], "asset class not found");
        AssetClassData storage data = assetClasses[assetClass];
        return (data.name, data.registry, data.active, data.nav, data.lastUpdated);
    }

    /**
     * @notice Get all registered asset class IDs
     * @return Array of asset class identifiers
     */
    function getAllAssetClasses() external view returns (bytes32[] memory) {
        return assetClassIds;
    }

    /**
     * @notice Get count of registered asset classes
     * @return Number of registered asset classes
     */
    function getAssetClassCount() external view returns (uint256) {
        return assetClassIds.length;
    }

    /**
     * @notice Calculate percentage change between two values
     * @param oldValue Previous value
     * @param newValue New value
     * @return Percentage change in basis points
     */
    function _calculateChangePercent(uint256 oldValue, uint256 newValue) internal pure returns (uint256) {
        if (oldValue == 0) return 0;

        uint256 diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
        return (diff * 10000) / oldValue;
    }

    /**
     * @notice Batch update NAV for multiple asset classes
     * @param classes Array of asset class identifiers
     * @param navs Array of corresponding NAV values
     */
    function batchUpdateNav(bytes32[] calldata classes, uint256[] calldata navs) external {
        require(classes.length == navs.length, "array length mismatch");

        for (uint256 i = 0; i < classes.length; i++) {
            // Use internal function to avoid repeated checks
            _updateNavInternal(classes[i], navs[i]);
        }
    }

    /**
     * @notice Internal NAV update function
     * @param assetClass Asset class identifier
     * @param newNav New NAV value
     */
    function _updateNavInternal(bytes32 assetClass, uint256 newNav) internal {
        require(assetClassExists[assetClass], "asset class not found");
        require(newNav > 0, "invalid NAV");

        AssetClassData storage data = assetClasses[assetClass];
        require(
            hasRole(GLOBAL_ORACLE_UPDATER_ROLE, msg.sender) || data.authorizedUpdaters[msg.sender],
            "not authorized for this asset class"
        );

        require(data.active, "asset class inactive");

        uint256 previousNav = data.nav;

        // Check change threshold
        if (previousNav > 0) {
            uint256 changePercent = _calculateChangePercent(previousNav, newNav);
            require(changePercent <= data.changeThreshold, "change exceeds threshold");
        }

        // Update NAV
        data.nav = newNav;
        data.lastUpdated = block.timestamp;

        emit NavUpdated(assetClass, newNav, previousNav, msg.sender, block.timestamp);
    }
}
