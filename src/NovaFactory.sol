// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NovaAssetVault} from "./NovaAssetVault.sol";
import {NovaTreasury} from "./NovaTreasury.sol";
import {FeeModule} from "./FeeModule.sol";
import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {MultiAssetNavOracle} from "./MultiAssetNavOracle.sol";
import {NovaStablecoinWrapper} from "./NovaStablecoinWrapper.sol";

/**
 * @title NovaFactory
 * @notice Factory contract for deploying Nova Protocol vault instances for different asset classes
 * @dev Creates complete vault ecosystems with shared oracle and compliance infrastructure
 */
contract NovaFactory is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    /// @notice Event emitted when a new vault ecosystem is deployed
    event VaultEcosystemDeployed(
        bytes32 indexed assetClass,
        address indexed vault,
        address indexed treasury,
        address feeModule,
        address asset,
        string name,
        string symbol
    );

    /// @notice Event emitted when implementation addresses are updated
    event ImplementationUpdated(string indexed contractType, address indexed newImplementation);

    /// @notice Event emitted when shared infrastructure is updated
    event SharedInfrastructureUpdated(string indexed component, address indexed newAddress);

    /// @notice Role that can deploy new vault ecosystems
    bytes32 public constant VAULT_DEPLOYER_ROLE = keccak256("VAULT_DEPLOYER_ROLE");

    /// @notice Role that can update implementation contracts
    bytes32 public constant IMPLEMENTATION_MANAGER_ROLE = keccak256("IMPLEMENTATION_MANAGER_ROLE");

    /// @notice Structure to hold deployment configuration for a vault ecosystem
    struct VaultConfig {
        string vaultName;
        string vaultSymbol;
        address asset;
        uint256 managementFeeBps;
        uint256 performanceFeeBps;
        uint256 penaltyBps;
        address managementFeeRecipient;
        address performanceFeeRecipient;
        address emergencyRecipient;
    }

    /// @notice Structure to hold information about a deployed vault ecosystem
    struct VaultEcosystem {
        address vault;
        address treasury;
        address feeModule;
        address asset;
        bytes32 assetClass;
        string name;
        string symbol;
        uint256 deployedAt;
        bool active;
    }

    /// @notice Shared infrastructure contracts
    MultiAssetNavOracle public navOracle;
    ComplianceRegistry public complianceRegistry;
    NovaStablecoinWrapper public stablecoinWrapper;
    FeeModule public feeModule; // Shared fee module for all vaults

    /// @notice Implementation contracts for proxy deployment
    address public vaultImplementation;
    address public treasuryImplementation;

    /// @notice Mapping from asset class to deployed vault ecosystem
    mapping(bytes32 => VaultEcosystem) public vaultEcosystems;

    /// @notice Array of all deployed asset classes for enumeration
    bytes32[] public deployedAssetClasses;

    /// @notice Mapping to check if asset class has been deployed
    mapping(bytes32 => bool) public isAssetClassDeployed;

    /// @notice Mapping from vault address to asset class
    mapping(address => bytes32) public vaultToAssetClass;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Nova Factory
     * @param admin Address to receive admin role
     * @param _navOracle Shared multi-asset NAV oracle
     * @param _complianceRegistry Shared compliance registry
     * @param _stablecoinWrapper Shared stablecoin wrapper
     * @param _feeModule Shared fee module for all vaults
     */
    function initialize(
        address admin,
        address _navOracle,
        address _complianceRegistry,
        address _stablecoinWrapper,
        address _feeModule
    ) public initializer {
        require(admin != address(0), "NovaFactory: zero admin address");
        require(_navOracle != address(0), "NovaFactory: zero oracle address");
        require(_complianceRegistry != address(0), "NovaFactory: zero compliance address");
        require(_stablecoinWrapper != address(0), "NovaFactory: zero wrapper address");
        require(_feeModule != address(0), "NovaFactory: zero fee module address");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(VAULT_DEPLOYER_ROLE, admin);
        _grantRole(IMPLEMENTATION_MANAGER_ROLE, admin);

        navOracle = MultiAssetNavOracle(_navOracle);
        complianceRegistry = ComplianceRegistry(_complianceRegistry);
        stablecoinWrapper = NovaStablecoinWrapper(_stablecoinWrapper);
        feeModule = FeeModule(_feeModule);
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Set implementation contracts for proxy deployment
     * @param _vaultImpl Vault implementation address
     * @param _treasuryImpl Treasury implementation address
     */
    function setImplementations(address _vaultImpl, address _treasuryImpl)
        external
        onlyRole(IMPLEMENTATION_MANAGER_ROLE)
    {
        require(_vaultImpl != address(0), "zero vault implementation");
        require(_treasuryImpl != address(0), "zero treasury implementation");

        vaultImplementation = _vaultImpl;
        treasuryImplementation = _treasuryImpl;

        emit ImplementationUpdated("vault", _vaultImpl);
        emit ImplementationUpdated("treasury", _treasuryImpl);
    }

    /**
     * @notice Deploy a complete vault ecosystem for a new asset class
     * @param assetClass Unique identifier for the asset class
     * @param config Vault configuration parameters
     * @param initialNav Initial NAV value for the asset class
     * @return vault Address of the deployed vault
     * @return treasury Address of the deployed treasury
     */
    function deployVaultEcosystem(bytes32 assetClass, VaultConfig memory config, uint256 initialNav)
        external
        onlyRole(VAULT_DEPLOYER_ROLE)
        returns (address vault, address treasury)
    {
        require(!isAssetClassDeployed[assetClass], "asset class already deployed");
        require(config.asset != address(0), "zero asset address");
        require(bytes(config.vaultName).length > 0, "empty vault name");
        require(bytes(config.vaultSymbol).length > 0, "empty vault symbol");
        require(initialNav > 0, "invalid initial NAV");

        // Verify implementation contracts are set
        require(vaultImplementation != address(0), "vault implementation not set");
        require(treasuryImplementation != address(0), "treasury implementation not set");

        // Register asset class in the oracle
        string memory assetClassName = string(abi.encodePacked(config.vaultName, " Asset Class"));
        navOracle.registerAssetClass(assetClass, assetClassName, address(0), initialNav);

        // Configure fee module for this asset class
        _configureFeeModuleForAssetClass(assetClass, config);

        // Deploy treasury
        treasury = _deployTreasury(assetClass, config);

        // Deploy vault
        vault = _deployVault(assetClass, config, treasury);

        // Update oracle registry to point to vault
        // Note: This would require an admin function in MultiAssetNavOracle to update registry

        // Configure relationships
        _configureEcosystem(vault, treasury, assetClass);

        // Store ecosystem information
        vaultEcosystems[assetClass] = VaultEcosystem({
            vault: vault,
            treasury: treasury,
            feeModule: address(feeModule), // Shared fee module
            asset: config.asset,
            assetClass: assetClass,
            name: config.vaultName,
            symbol: config.vaultSymbol,
            deployedAt: block.timestamp,
            active: true
        });

        deployedAssetClasses.push(assetClass);
        isAssetClassDeployed[assetClass] = true;
        vaultToAssetClass[vault] = assetClass;

        emit VaultEcosystemDeployed(
            assetClass, vault, treasury, address(feeModule), config.asset, config.vaultName, config.vaultSymbol
        );

        return (vault, treasury);
    }

    /**
     * @notice Configure the shared fee module for a new asset class
     */
    function _configureFeeModuleForAssetClass(bytes32 assetClass, VaultConfig memory config) internal {
        // Set asset-class-specific fees
        feeModule.setFeesForAssetClass(
            assetClass, config.managementFeeBps, config.performanceFeeBps, config.penaltyBps
        );

        // Set asset-class-specific recipients
        feeModule.setRecipientsForAssetClass(
            assetClass, config.managementFeeRecipient, config.performanceFeeRecipient, config.emergencyRecipient
        );
    }

    /**
     * @notice Deploy treasury proxy using CREATE2 for deterministic addresses
     */
    function _deployTreasury(bytes32 assetClass, VaultConfig memory config) internal returns (address) {
        bytes memory initData = abi.encodeWithSelector(
            NovaTreasury.initialize.selector,
            address(this), // factory as temporary admin
            address(complianceRegistry),
            address(navOracle),
            address(stablecoinWrapper),
            config.emergencyRecipient,
            assetClass
        );

        // Use CREATE2 for deterministic deployment
        bytes32 salt = keccak256(abi.encodePacked(assetClass, "treasury"));
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(treasuryImplementation, initData);
        return address(proxy);
    }

    /**
     * @notice Deploy vault proxy using CREATE2 for deterministic addresses
     */
    function _deployVault(bytes32 assetClass, VaultConfig memory config, address /* treasury */ )
        internal
        returns (address)
    {
        // Create modified vault that uses asset class for oracle queries
        bytes memory initData = abi.encodeWithSelector(
            NovaAssetVault.initialize.selector,
            IERC20(config.asset),
            config.vaultName,
            config.vaultSymbol,
            address(this), // factory as temporary admin
            address(complianceRegistry),
            address(feeModule), // Shared fee module
            address(navOracle),
            assetClass
        );

        // Use CREATE2 for deterministic deployment
        bytes32 salt = keccak256(abi.encodePacked(assetClass, config.asset));
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(vaultImplementation, initData);
        return address(proxy);
    }

    /**
     * @notice Configure relationships between ecosystem components
     */
    function _configureEcosystem(address vault, address treasury, bytes32 assetClass) internal {
        // Grant oracle updater role to treasury for this asset class
        navOracle.grantAssetClassUpdater(assetClass, treasury);

        // Set treasury in vault
        NovaAssetVault(vault).setTreasury(treasury);

        // Authorize vault in treasury
        NovaTreasury(treasury).setVaultAuthorization(vault, true);

        // Transfer admin rights from factory to deployer
        NovaAssetVault vaultContract = NovaAssetVault(vault);
        NovaTreasury treasuryContract = NovaTreasury(treasury);
        
        bytes32 adminRole = vaultContract.DEFAULT_ADMIN_ROLE();
        
        // Grant deployer all admin roles on vault
        vaultContract.grantRole(adminRole, msg.sender);
        vaultContract.grantRole(vaultContract.OPERATOR_ROLE(), msg.sender);
        vaultContract.grantRole(vaultContract.PAUSER_ROLE(), msg.sender);
        vaultContract.grantRole(vaultContract.TREASURY_ROLE(), msg.sender);
        vaultContract.grantRole(vaultContract.COMPLIANCE_ADMIN_ROLE(), msg.sender);
        vaultContract.grantRole(vaultContract.ASSET_CLASS_MANAGER_ROLE(), msg.sender);
        
        // Grant deployer all admin roles on treasury
        treasuryContract.grantRole(adminRole, msg.sender);
        treasuryContract.grantRole(treasuryContract.OPERATOR_ROLE(), msg.sender);
        treasuryContract.grantRole(treasuryContract.TREASURY_MANAGER_ROLE(), msg.sender);
        treasuryContract.grantRole(treasuryContract.PAUSER_ROLE(), msg.sender);
        treasuryContract.grantRole(treasuryContract.EMERGENCY_ROLE(), msg.sender);
        
        // Revoke factory's admin roles
        vaultContract.renounceRole(adminRole, address(this));
        treasuryContract.renounceRole(adminRole, address(this));
    }

    /**
     * @notice Get vault ecosystem information
     * @param assetClass Asset class identifier
     * @return ecosystem Complete ecosystem information
     */
    function getVaultEcosystem(bytes32 assetClass) external view returns (VaultEcosystem memory ecosystem) {
        require(isAssetClassDeployed[assetClass], "asset class not deployed");
        return vaultEcosystems[assetClass];
    }

    /**
     * @notice Get asset class for a vault address
     * @param vault Vault address
     * @return assetClass Asset class identifier
     */
    function getAssetClass(address vault) external view returns (bytes32 assetClass) {
        return vaultToAssetClass[vault];
    }

    /**
     * @notice Get all deployed asset classes
     * @return Array of asset class identifiers
     */
    function getAllAssetClasses() external view returns (bytes32[] memory) {
        return deployedAssetClasses;
    }

    /**
     * @notice Get count of deployed ecosystems
     * @return Number of deployed ecosystems
     */
    function getDeployedCount() external view returns (uint256) {
        return deployedAssetClasses.length;
    }

    /**
     * @notice Set ecosystem active status
     * @param assetClass Asset class identifier
     * @param active New active status
     */
    function setEcosystemActive(bytes32 assetClass, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isAssetClassDeployed[assetClass], "asset class not deployed");

        vaultEcosystems[assetClass].active = active;

        // Also update oracle status
        navOracle.setAssetClassActive(assetClass, active);
    }

    /**
     * @notice Update shared infrastructure component
     * @param component Component name ("oracle", "compliance", "wrapper", "feeModule")
     * @param newAddress New component address
     */
    function updateSharedInfrastructure(string memory component, address newAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newAddress != address(0), "zero address");

        bytes32 componentHash = keccak256(abi.encodePacked(component));

        if (componentHash == keccak256(abi.encodePacked("oracle"))) {
            navOracle = MultiAssetNavOracle(newAddress);
        } else if (componentHash == keccak256(abi.encodePacked("compliance"))) {
            complianceRegistry = ComplianceRegistry(newAddress);
        } else if (componentHash == keccak256(abi.encodePacked("wrapper"))) {
            stablecoinWrapper = NovaStablecoinWrapper(newAddress);
        } else if (componentHash == keccak256(abi.encodePacked("feeModule"))) {
            feeModule = FeeModule(newAddress);
        } else {
            revert("unknown component");
        }

        emit SharedInfrastructureUpdated(component, newAddress);
    }

    /**
     * @notice Batch deploy multiple vault ecosystems
     * @param assetClasses Array of asset class identifiers
     * @param configs Array of vault configurations
     * @param initialNavs Array of initial NAV values
     * @return vaults Array of deployed vault addresses
     * @return treasuries Array of deployed treasury addresses
     */
    function batchDeployEcosystems(
        bytes32[] memory assetClasses,
        VaultConfig[] memory configs,
        uint256[] memory initialNavs
    ) external onlyRole(VAULT_DEPLOYER_ROLE) returns (address[] memory vaults, address[] memory treasuries) {
        require(assetClasses.length == configs.length && configs.length == initialNavs.length, "array length mismatch");

        vaults = new address[](assetClasses.length);
        treasuries = new address[](assetClasses.length);

        for (uint256 i = 0; i < assetClasses.length; i++) {
            (vaults[i], treasuries[i]) = this.deployVaultEcosystem(assetClasses[i], configs[i], initialNavs[i]);
        }

        return (vaults, treasuries);
    }

    /**
     * @notice Get ecosystem summary for dashboard/UI
     * @param assetClass Asset class identifier
     * @return vault Vault address
     * @return totalAssets Total assets under management
     * @return nav Current NAV
     * @return active Whether ecosystem is active
     */
    function getEcosystemSummary(bytes32 assetClass)
        external
        view
        returns (address vault, uint256 totalAssets, uint256 nav, bool active)
    {
        require(isAssetClassDeployed[assetClass], "asset class not deployed");

        VaultEcosystem memory ecosystem = vaultEcosystems[assetClass];
        vault = ecosystem.vault;
        active = ecosystem.active;

        // Get NAV from oracle
        (nav,) = navOracle.getNav(assetClass);

        // Get total assets from vault
        totalAssets = NovaAssetVault(vault).totalAssets();

        return (vault, totalAssets, nav, active);
    }

    /**
     * @notice Compute deterministic address for a vault before deployment
     * @param assetClass Asset class identifier
     * @param asset Underlying asset address
     * @return Predicted vault address
     */
    function computeVaultAddress(bytes32 assetClass, address asset) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(assetClass, asset));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), salt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode))
            )
        );
        return address(uint160(uint256(hash)));
    }

    /**
     * @notice Compute deterministic address for a treasury before deployment
     * @param assetClass Asset class identifier
     * @return Predicted treasury address
     */
    function computeTreasuryAddress(bytes32 assetClass) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(assetClass, "treasury"));
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), salt, keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode))
            )
        );
        return address(uint160(uint256(hash)));
    }

}
