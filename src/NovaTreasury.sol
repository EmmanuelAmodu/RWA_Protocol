// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title NovaTreasury
/// @notice Simplified treasury contract for managing Nova vault assets using a single wrapper token
/// @dev This contract receives wrapper tokens from Nova vaults and manages them for business operations,
///      yield generation, and strategic investments. Uses a single ERC20 wrapper token that can be
///      backed by multiple stablecoins.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ComplianceRegistry} from "./ComplianceRegistry.sol";
import {MultiAssetNavOracle} from "./MultiAssetNavOracle.sol";
import {NovaStablecoinWrapper} from "./NovaStablecoinWrapper.sol";
import {INovaTreasury} from "./interfaces/INovaTreasury.sol";

contract NovaTreasury is
    Initializable,
    INovaTreasury,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Using events and structs from INovaTreasury interface

    // State variables
    ComplianceRegistry public compliance;
    MultiAssetNavOracle public navOracle;
    NovaStablecoinWrapper public asset; // Single wrapper token asset

    /// @notice Asset class this treasury manages
    bytes32 public assetClass;

    // Asset tracking
    uint256 public totalReceived;
    uint256 public totalDeployed;
    uint256 public totalReturned;
    uint256 public currentBalance;

    // Deployment tracking
    mapping(uint256 => Deployment) public deployments;
    uint256 public nextDeploymentId;

    // Vault tracking
    mapping(address => bool) public authorizedVaults;

    // Emergency withdrawal settings
    address public emergencyRecipient;
    bool public emergencyMode;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the treasury with a single wrapper token asset
     * @param admin Address to receive admin roles
     * @param complianceRegistry Address of the compliance registry
     * @param navOracleAddress Address of the multi-asset NAV oracle
     * @param wrapperToken Address of the stablecoin wrapper token
     * @param emergencyRecipient_ Address to receive funds in emergency situations
     * @param _assetClass Asset class identifier for this treasury
     */
    function initialize(
        address admin,
        address complianceRegistry,
        address navOracleAddress,
        address wrapperToken,
        address emergencyRecipient_,
        bytes32 _assetClass
    ) public initializer {
        require(admin != address(0), "zero admin address");
        require(complianceRegistry != address(0), "zero compliance address");
        require(wrapperToken != address(0), "zero wrapper token address");
        require(emergencyRecipient_ != address(0), "zero emergency recipient");
        require(_assetClass != bytes32(0), "zero asset class");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(TREASURY_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);

        compliance = ComplianceRegistry(complianceRegistry);
        navOracle = MultiAssetNavOracle(navOracleAddress);
        asset = NovaStablecoinWrapper(wrapperToken);
        emergencyRecipient = emergencyRecipient_;
        assetClass = _assetClass;
        nextDeploymentId = 1;
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    modifier onlyAuthorizedVault() {
        require(authorizedVaults[msg.sender], "unauthorized vault");
        _;
    }

    modifier onlyEligible(address account) {
        require(compliance.isEligible(account), "account not eligible");
        _;
    }

    modifier notEmergencyMode() {
        require(!emergencyMode, "emergency mode active");
        _;
    }

    /// @notice Authorize or deauthorize a vault to interact with the treasury
    /// @param vault Address of the vault
    /// @param authorized Whether the vault should be authorized
    function setVaultAuthorization(address vault, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(vault != address(0), "zero vault address");
        authorizedVaults[vault] = authorized;
        emit VaultAuthorized(vault, authorized);
    }

    /// @notice Update the multi-asset NAV oracle address
    /// @param newOracle Address of the new NAV oracle
    function setNavOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOracle != address(0), "zero oracle address");
        address oldOracle = address(navOracle);
        navOracle = MultiAssetNavOracle(newOracle);
        emit NavOracleUpdated(oldOracle, newOracle);
    }

    /// @notice Receive wrapper tokens from authorized vaults
    /// @param amount Amount of wrapper tokens being received
    /// @param memo Description of the transfer
    function receiveAssets(uint256 amount, string calldata memo)
        external
        onlyAuthorizedVault
        whenNotPaused
        notEmergencyMode
        nonReentrant
    {
        require(amount > 0, "zero amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        totalReceived += amount;
        currentBalance += amount;

        emit AssetReceived(msg.sender, amount, memo);
    }

    /// @notice Deploy wrapper tokens for off-chain business operations
    /// @param amount Amount to deploy
    /// @param destination Address to receive the assets
    /// @param purpose Description of the deployment purpose
    /// @param expectedReturn Expected return amount
    function deployAssets(uint256 amount, address destination, string calldata purpose, uint256 expectedReturn)
        external
        onlyRole(TREASURY_MANAGER_ROLE)
        onlyEligible(destination)
        whenNotPaused
        notEmergencyMode
        nonReentrant
    {
        require(amount > 0, "zero amount");
        require(destination != address(0), "zero destination");
        require(currentBalance >= amount, "insufficient balance");

        uint256 deploymentId = nextDeploymentId++;

        deployments[deploymentId] = Deployment({
            amount: amount,
            destination: destination,
            purpose: purpose,
            timestamp: block.timestamp,
            expectedReturn: expectedReturn,
            actualReturn: 0,
            isActive: true
        });

        totalDeployed += amount;
        currentBalance -= amount;

        IERC20(asset).safeTransfer(destination, amount);

        emit AssetDeployed(deploymentId, amount, destination, purpose);
    }

    /// @notice Record the return of wrapper tokens from a deployment
    /// @param deploymentId ID of the deployment being returned
    /// @param amount Amount being returned
    function recordAssetReturn(uint256 deploymentId, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        Deployment storage deployment = deployments[deploymentId];
        require(deployment.isActive, "deployment not active");
        require(amount > 0, "zero amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        deployment.actualReturn = amount;
        deployment.isActive = false;

        totalReturned += amount;
        currentBalance += amount;

        // Calculate profit/loss
        uint256 profit = amount > deployment.amount ? amount - deployment.amount : 0;

        emit AssetReturned(deploymentId, amount, profit);

        // Update NAV oracle if significant return
        if (amount >= deployment.amount / 10) {
            // 10% threshold
            _updateNavOracle();
        }
    }

    /// @notice Withdraw wrapper tokens back to an authorized vault
    /// @param vault Address of the vault to receive assets
    /// @param amount Amount to withdraw
    function withdrawToVault(address vault, uint256 amount)
        external
        onlyRole(TREASURY_MANAGER_ROLE)
        onlyEligible(vault)
        whenNotPaused
        nonReentrant
    {
        require(authorizedVaults[vault], "unauthorized vault");
        require(amount > 0, "zero amount");
        require(currentBalance >= amount, "insufficient balance");

        currentBalance -= amount;

        IERC20(asset).safeTransfer(vault, amount);

        emit AssetWithdrawn(vault, amount);
    }

    /// @notice Activate emergency mode
    function activateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyMode = true;
        _pause();
        emit EmergencyModeActivated(msg.sender);
    }

    /// @notice Emergency withdrawal of all wrapper tokens
    function emergencyWithdraw() external onlyRole(EMERGENCY_ROLE) {
        require(emergencyMode, "not in emergency mode");

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            IERC20(asset).safeTransfer(emergencyRecipient, balance);
            emit EmergencyWithdrawal(balance, emergencyRecipient);
        }
    }

    /// @notice Manually update NAV oracle with current treasury valuation
    /// @dev Can be called by treasury managers to sync NAV after operations
    function updateNavOracle() external onlyRole(TREASURY_MANAGER_ROLE) {
        _updateNavOracle();
    }

    /// @notice Update multi-asset NAV oracle with current treasury valuation for this asset class
    function _updateNavOracle() internal {
        if (address(navOracle) != address(0)) {
            navOracle.updateNav(assetClass, currentBalance);
        }
    }

    /// @notice Get the asset class managed by this treasury
    /// @return Asset class identifier
    function getAssetClass() external view returns (bytes32) {
        return assetClass;
    }

    /// @notice Get information about a specific deployment
    /// @param deploymentId ID of the deployment
    /// @return Deployment information
    function getDeployment(uint256 deploymentId) external view returns (Deployment memory) {
        return deployments[deploymentId];
    }

    /// @notice Get the wrapper token address
    /// @return Address of the wrapper token
    function getAssetAddress() external view returns (address) {
        return address(asset);
    }

    /// @notice Get current balance of wrapper tokens in the treasury
    /// @return Current balance in the treasury
    function getCurrentBalance() external view returns (uint256) {
        return currentBalance;
    }

    /// @notice Get total value of assets in the treasury (same as current balance)
    /// @return Total value in the treasury
    function getTotalValue() external view returns (uint256) {
        return currentBalance;
    }

    /// @notice Get treasury statistics
    /// @return totalReceived_ Total amount received from vaults
    /// @return totalDeployed_ Total amount deployed for operations
    /// @return totalReturned_ Total amount returned from operations
    /// @return currentBalance_ Current balance in the treasury
    function getTreasuryStats()
        external
        view
        returns (uint256 totalReceived_, uint256 totalDeployed_, uint256 totalReturned_, uint256 currentBalance_)
    {
        return (totalReceived, totalDeployed, totalReturned, currentBalance);
    }

    /// @notice Pause contract functions
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause contract functions
    function unpause() external onlyRole(PAUSER_ROLE) {
        require(!emergencyMode, "cannot unpause in emergency mode");
        _unpause();
    }
}
