// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title INovaTreasury
/// @notice Interface for the simplified Nova Treasury contract using a single wrapper token
/// @dev This interface defines the key functions that external contracts need to interact with the treasury

interface INovaTreasury {
    /// @notice Information about a wrapper token deployment
    struct Deployment {
        uint256 amount; // Amount deployed
        address destination; // Where the assets were sent
        string purpose; // Description of the deployment purpose
        uint256 timestamp; // When the deployment happened
        uint256 expectedReturn; // Expected return amount
        uint256 actualReturn; // Actual return amount (0 if not returned)
        bool isActive; // Whether the deployment is still active
    }

    // Events
    event AssetReceived(address indexed vault, uint256 amount, string memo);
    event AssetDeployed(uint256 indexed deploymentId, uint256 amount, address indexed destination, string purpose);
    event AssetReturned(uint256 indexed deploymentId, uint256 amount, uint256 profit);
    event AssetWithdrawn(address indexed vault, uint256 amount);
    event VaultAuthorized(address indexed vault, bool authorized);
    event EmergencyModeActivated(address indexed activator);
    event EmergencyWithdrawal(uint256 amount, address indexed recipient);
    event NavOracleUpdated(address indexed oldOracle, address indexed newOracle);

    /// @notice Authorize or deauthorize a vault to interact with the treasury
    function setVaultAuthorization(address vault, bool authorized) external;

    /// @notice Receive wrapper tokens from authorized vaults
    function receiveAssets(uint256 amount, string calldata memo) external;

    /// @notice Deploy wrapper tokens for off-chain business operations
    function deployAssets(uint256 amount, address destination, string calldata purpose, uint256 expectedReturn) external;

    /// @notice Record the return of wrapper tokens from a deployment
    function recordAssetReturn(uint256 deploymentId, uint256 amount) external;

    /// @notice Withdraw wrapper tokens back to an authorized vault
    function withdrawToVault(address vault, uint256 amount) external;

    /// @notice Get information about a specific deployment
    function getDeployment(uint256 deploymentId) external view returns (Deployment memory);

    /// @notice Get the wrapper token address
    function getAssetAddress() external view returns (address);

    /// @notice Get current balance of wrapper tokens in the treasury
    function getCurrentBalance() external view returns (uint256);

    /// @notice Get total value of assets in the treasury
    function getTotalValue() external view returns (uint256);

    /// @notice Get treasury statistics
    function getTreasuryStats()
        external
        view
        returns (uint256 totalReceived, uint256 totalDeployed, uint256 totalReturned, uint256 currentBalance);

    /// @notice Check if a vault is authorized
    function authorizedVaults(address vault) external view returns (bool);

    /// @notice Update the NAV oracle address
    function setNavOracle(address newOracle) external;

    /// @notice Manually update NAV oracle with current treasury valuation
    function updateNavOracle() external;

    /// @notice Activate emergency mode
    function activateEmergencyMode() external;

    /// @notice Emergency withdrawal of all wrapper tokens
    function emergencyWithdraw() external;

    /// @notice Pause contract functions
    function pause() external;

    /// @notice Unpause contract functions
    function unpause() external;
}
