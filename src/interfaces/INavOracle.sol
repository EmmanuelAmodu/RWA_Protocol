// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title INavOracle
 * @notice Interface for Net Asset Value oracle contracts
 * @dev Provides standardized access to NAV data with change detection and freshness checks
 */
interface INavOracle {
    // Events
    event NavUpdated(uint256 oldValue, uint256 newValue, uint256 change);
    event SignificantNavChange(uint256 oldValue, uint256 newValue, uint256 changePercentage);

    /// @notice Update the NAV to a new value
    /// @param newValue The new NAV value
    function updateNav(uint256 newValue) external;

    /// @notice Return the total assets value and last update timestamp
    function getMark() external view returns (uint256, uint256);

    /// @notice Get the current NAV value
    function getCurrentNav() external view returns (uint256);

    /// @notice Check how stale the NAV data is
    function getNavAge() external view returns (uint256);

    /// @notice Check if NAV data is fresh
    function isNavFresh(uint256 maxAge) external view returns (bool);
}
