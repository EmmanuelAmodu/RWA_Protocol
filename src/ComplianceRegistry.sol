// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title ComplianceRegistry
/// @notice Simple allowlist and sanctions registry used by Nova vaults and share tokens
/// @dev This contract is intentionally minimal.  In production you should integrate
///       with off‑chain KYC/AML providers and add mechanisms to manage jurisdictions,
///       revocation, and sanctions lists.  Only addresses marked as `eligible` are
///       allowed to interact with the vault and transfer shares.

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ComplianceRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant COMPLIANCE_OP_ROLE = keccak256("COMPLIANCE_OP_ROLE");

    /// @dev whether an address is eligible to deposit, receive shares, or redeem
    mapping(address => bool) private _eligible;

    /// @dev per-asset-class eligibility: assetClass => account => eligible
    mapping(bytes32 => mapping(address => bool)) private _assetClassEligibility;

    /// @dev global asset class settings: if true, uses global eligibility; if false, uses per-asset-class
    mapping(bytes32 => bool) public useGlobalEligibility;

    /// @notice Emitted when the eligibility of an account changes
    event EligibilityUpdated(address indexed account, bool eligible);

    /// @notice Emitted when asset class eligibility is updated
    event AssetClassEligibilityUpdated(bytes32 indexed assetClass, address indexed account, bool eligible);

    /// @notice Emitted when asset class is registered
    event AssetClassRegistered(bytes32 indexed assetClass, bool useGlobal);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the compliance registry
     * @param admin Admin address
     */
    function initialize(address admin) public initializer {
        require(admin != address(0), "ComplianceRegistry: zero admin address");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_OP_ROLE, admin);
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice Check if an account is eligible (global)
    function isEligible(address account) external view returns (bool) {
        return _eligible[account];
    }

    /// @notice Check if an account is eligible for a specific asset class
    /// @param assetClass Asset class identifier
    /// @param account Account to check
    /// @return True if eligible for this asset class
    function isEligibleForAssetClass(bytes32 assetClass, address account) external view returns (bool) {
        // If using global eligibility, check global mapping
        if (useGlobalEligibility[assetClass]) {
            return _eligible[account];
        }
        // Otherwise check asset-specific eligibility
        return _assetClassEligibility[assetClass][account];
    }

    /// @notice Check if a transfer is allowed (global)
    /// @dev In a real implementation you would check additional conditions such
    ///      as jurisdictions, daily limits, sanctions, etc.
    function isTransferAllowed(
        address from,
        address to,
        uint256 /*amount*/
    )
        external
        view
        returns (bool)
    {
        // If minting (from == address(0)) or burning (to == address(0)), allow.
        if (from == address(0) || to == address(0)) {
            return true;
        }
        return _eligible[from] && _eligible[to];
    }

    /// @notice Check if a transfer is allowed for a specific asset class
    /// @param assetClass Asset class identifier
    /// @param from Sender address
    /// @param to Receiver address
    /// @return True if transfer is allowed
    function isTransferAllowedForAssetClass(
        bytes32 assetClass,
        address from,
        address to,
        uint256 /*amount*/
    )
        external
        view
        returns (bool)
    {
        // If minting or burning, allow
        if (from == address(0) || to == address(0)) {
            return true;
        }

        // Check eligibility based on asset class settings
        bool fromEligible;
        bool toEligible;

        if (useGlobalEligibility[assetClass]) {
            fromEligible = _eligible[from];
            toEligible = _eligible[to];
        } else {
            fromEligible = _assetClassEligibility[assetClass][from];
            toEligible = _assetClassEligibility[assetClass][to];
        }

        return fromEligible && toEligible;
    }

    /// @notice Set the eligibility of an account (global)
    /// @param account The account to update
    /// @param eligible Whether the account is eligible
    function setEligible(address account, bool eligible) external onlyRole(COMPLIANCE_OP_ROLE) {
        _eligible[account] = eligible;
        emit EligibilityUpdated(account, eligible);
    }

    /// @notice Register a new asset class with compliance settings
    /// @param assetClass Asset class identifier
    /// @param _useGlobalEligibility Whether to use global or asset-specific eligibility
    function registerAssetClass(bytes32 assetClass, bool _useGlobalEligibility)
        external
        onlyRole(COMPLIANCE_OP_ROLE)
    {
        require(assetClass != bytes32(0), "zero asset class");
        useGlobalEligibility[assetClass] = _useGlobalEligibility;
        emit AssetClassRegistered(assetClass, _useGlobalEligibility);
    }

    /// @notice Set eligibility for a specific asset class
    /// @param assetClass Asset class identifier
    /// @param account Account to update
    /// @param eligible Whether the account is eligible for this asset class
    function setEligibleForAssetClass(bytes32 assetClass, address account, bool eligible)
        external
        onlyRole(COMPLIANCE_OP_ROLE)
    {
        require(assetClass != bytes32(0), "zero asset class");
        require(!useGlobalEligibility[assetClass], "asset class uses global eligibility");

        _assetClassEligibility[assetClass][account] = eligible;
        emit AssetClassEligibilityUpdated(assetClass, account, eligible);
    }

    /// @notice Batch set eligibility for multiple accounts in an asset class
    /// @param assetClass Asset class identifier
    /// @param accounts Array of accounts to update
    /// @param eligible Eligibility status to set for all accounts
    function batchSetEligibleForAssetClass(bytes32 assetClass, address[] calldata accounts, bool eligible)
        external
        onlyRole(COMPLIANCE_OP_ROLE)
    {
        require(assetClass != bytes32(0), "zero asset class");
        require(!useGlobalEligibility[assetClass], "asset class uses global eligibility");

        for (uint256 i = 0; i < accounts.length; i++) {
            _assetClassEligibility[assetClass][accounts[i]] = eligible;
            emit AssetClassEligibilityUpdated(assetClass, accounts[i], eligible);
        }
    }

    /// @notice Update whether an asset class uses global eligibility
    /// @param assetClass Asset class identifier
    /// @param _useGlobalEligibility New setting
    function setAssetClassUseGlobalEligibility(bytes32 assetClass, bool _useGlobalEligibility)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(assetClass != bytes32(0), "zero asset class");
        useGlobalEligibility[assetClass] = _useGlobalEligibility;
        emit AssetClassRegistered(assetClass, _useGlobalEligibility);
    }
}
