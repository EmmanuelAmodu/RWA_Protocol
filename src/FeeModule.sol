// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title FeeModule
/// @notice Stores fee parameters and provides simple accrual hooks for the Nova vault
/// @dev All fee percentages are expressed in basis points (bps), where 1 bps = 0.01%.

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeModule is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant PARAM_SETTER_ROLE = keccak256("PARAM_SETTER_ROLE");

    /// @notice Structure to hold fee parameters for an asset class
    struct FeeParams {
        uint256 managementFeeBps; // Management fee in basis points per year
        uint256 performanceFeeBps; // Performance fee in basis points
        uint256 penaltyBps; // Early withdrawal penalty in basis points
        address managementFeeRecipient;
        address performanceFeeRecipient;
        address penaltyRecipient;
        bool isSet; // Whether fees are set for this asset class
    }

    // Global default fees (used if asset class doesn't have specific fees)
    uint256 public managementFeeBps;
    uint256 public performanceFeeBps;
    uint256 public penaltyBps;

    // Global default recipients
    address public managementFeeRecipient;
    address public performanceFeeRecipient;
    address public penaltyRecipient;

    /// @notice Per-asset-class fee parameters
    mapping(bytes32 => FeeParams) public assetClassFees;

    event FeesUpdated(uint256 managementFeeBps, uint256 performanceFeeBps, uint256 penaltyBps);
    event RecipientsUpdated(address managementFeeRecipient, address performanceFeeRecipient, address penaltyRecipient);
    event AssetClassFeesUpdated(
        bytes32 indexed assetClass,
        uint256 managementFeeBps,
        uint256 performanceFeeBps,
        uint256 penaltyBps
    );
    event AssetClassRecipientsUpdated(
        bytes32 indexed assetClass,
        address managementFeeRecipient,
        address performanceFeeRecipient,
        address penaltyRecipient
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the fee module (shared across all asset classes)
     * @param admin Admin address
     * @param _managementFeeBps Default management fee in basis points
     * @param _performanceFeeBps Default performance fee in basis points
     * @param _penaltyBps Default penalty in basis points
     * @param _managementFeeRecipient Default management fee recipient
     * @param _performanceFeeRecipient Default performance fee recipient
     */
    function initialize(
        address admin,
        uint256 _managementFeeBps,
        uint256 _performanceFeeBps,
        uint256 _penaltyBps,
        address _managementFeeRecipient,
        address _performanceFeeRecipient
    ) public initializer {
        require(admin != address(0), "FeeModule: zero admin address");
        require(_managementFeeRecipient != address(0), "FeeModule: zero management fee recipient");
        require(_performanceFeeRecipient != address(0), "FeeModule: zero performance fee recipient");
        require(_managementFeeBps <= 5000, "mgmt too high");
        require(_performanceFeeBps <= 5000, "perf too high");
        require(_penaltyBps <= 10000, "penalty too high");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAM_SETTER_ROLE, admin);

        // Set global defaults (used when asset class doesn't have specific fees)
        managementFeeBps = _managementFeeBps;
        performanceFeeBps = _performanceFeeBps;
        penaltyBps = _penaltyBps;
        managementFeeRecipient = _managementFeeRecipient;
        performanceFeeRecipient = _performanceFeeRecipient;
        penaltyRecipient = _managementFeeRecipient; // Use management recipient as default penalty recipient
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setFees(uint256 mgmtBps, uint256 perfBps, uint256 penBps) external onlyRole(PARAM_SETTER_ROLE) {
        require(mgmtBps <= 5000, "mgmt too high");
        require(perfBps <= 5000, "perf too high");
        require(penBps <= 10000, "penalty too high");
        managementFeeBps = mgmtBps;
        performanceFeeBps = perfBps;
        penaltyBps = penBps;
        emit FeesUpdated(mgmtBps, perfBps, penBps);
    }

    function setRecipients(address mgmtRecip, address perfRecip, address penRecip)
        external
        onlyRole(PARAM_SETTER_ROLE)
    {
        require(mgmtRecip != address(0) && perfRecip != address(0) && penRecip != address(0), "zero");
        managementFeeRecipient = mgmtRecip;
        performanceFeeRecipient = perfRecip;
        penaltyRecipient = penRecip;
        emit RecipientsUpdated(mgmtRecip, perfRecip, penRecip);
    }

    /// @notice Set fees for a specific asset class
    /// @param _assetClass Asset class identifier
    /// @param mgmtBps Management fee in basis points
    /// @param perfBps Performance fee in basis points
    /// @param penBps Penalty in basis points
    function setFeesForAssetClass(bytes32 _assetClass, uint256 mgmtBps, uint256 perfBps, uint256 penBps)
        external
        onlyRole(PARAM_SETTER_ROLE)
    {
        require(_assetClass != bytes32(0), "zero asset class");
        require(mgmtBps <= 5000, "mgmt too high");
        require(perfBps <= 5000, "perf too high");
        require(penBps <= 10000, "penalty too high");

        FeeParams storage params = assetClassFees[_assetClass];
        params.managementFeeBps = mgmtBps;
        params.performanceFeeBps = perfBps;
        params.penaltyBps = penBps;
        params.isSet = true;

        emit AssetClassFeesUpdated(_assetClass, mgmtBps, perfBps, penBps);
    }

    /// @notice Set recipients for a specific asset class
    /// @param _assetClass Asset class identifier
    /// @param mgmtRecip Management fee recipient
    /// @param perfRecip Performance fee recipient
    /// @param penRecip Penalty recipient
    function setRecipientsForAssetClass(
        bytes32 _assetClass,
        address mgmtRecip,
        address perfRecip,
        address penRecip
    ) external onlyRole(PARAM_SETTER_ROLE) {
        require(_assetClass != bytes32(0), "zero asset class");
        require(mgmtRecip != address(0) && perfRecip != address(0) && penRecip != address(0), "zero");

        FeeParams storage params = assetClassFees[_assetClass];
        params.managementFeeRecipient = mgmtRecip;
        params.performanceFeeRecipient = perfRecip;
        params.penaltyRecipient = penRecip;
        params.isSet = true;

        emit AssetClassRecipientsUpdated(_assetClass, mgmtRecip, perfRecip, penRecip);
    }

    /// @notice Get fee parameters for an asset class (falls back to global if not set)
    /// @param _assetClass Asset class identifier
    /// @return mgmtBps Management fee in basis points
    /// @return perfBps Performance fee in basis points
    /// @return penBps Penalty in basis points
    function getFeesForAssetClass(bytes32 _assetClass)
        public
        view
        returns (uint256 mgmtBps, uint256 perfBps, uint256 penBps)
    {
        FeeParams storage params = assetClassFees[_assetClass];
        if (params.isSet) {
            return (params.managementFeeBps, params.performanceFeeBps, params.penaltyBps);
        }
        return (managementFeeBps, performanceFeeBps, penaltyBps);
    }

    /// @notice Get recipients for an asset class (falls back to global if not set)
    /// @param _assetClass Asset class identifier
    /// @return mgmtRecip Management fee recipient
    /// @return perfRecip Performance fee recipient
    /// @return penRecip Penalty recipient
    function getRecipientsForAssetClass(bytes32 _assetClass)
        public
        view
        returns (address mgmtRecip, address perfRecip, address penRecip)
    {
        FeeParams storage params = assetClassFees[_assetClass];
        if (params.isSet && params.managementFeeRecipient != address(0)) {
            return (params.managementFeeRecipient, params.performanceFeeRecipient, params.penaltyRecipient);
        }
        return (managementFeeRecipient, performanceFeeRecipient, penaltyRecipient);
    }

    /// @notice Compute management fee due since the last accrual
    /// @dev For a full implementation you would integrate with a timestamped accrual schedule.
    function computeManagementFee(uint256 totalAssets, uint256 timeElapsed, uint256 yearSeconds)
        external
        view
        returns (uint256)
    {
        return (totalAssets * managementFeeBps * timeElapsed) / (yearSeconds * 10000);
    }

    /// @notice Compute management fee for a specific asset class
    function computeManagementFeeForAssetClass(
        bytes32 _assetClass,
        uint256 totalAssets,
        uint256 timeElapsed,
        uint256 yearSeconds
    ) external view returns (uint256) {
        (uint256 mgmtBps,,) = getFeesForAssetClass(_assetClass);
        return (totalAssets * mgmtBps * timeElapsed) / (yearSeconds * 10000);
    }

    /// @notice Compute performance fee on a gain
    function computePerformanceFee(uint256 gain) external view returns (uint256) {
        return (gain * performanceFeeBps) / 10000;
    }

    /// @notice Compute performance fee for a specific asset class
    function computePerformanceFeeForAssetClass(bytes32 _assetClass, uint256 gain) external view returns (uint256) {
        (, uint256 perfBps,) = getFeesForAssetClass(_assetClass);
        return (gain * perfBps) / 10000;
    }

    /// @notice Compute penalty for early withdrawal on a given amount
    function computePenalty(uint256 amount) external view returns (uint256) {
        return (amount * penaltyBps) / 10000;
    }

    /// @notice Compute penalty for a specific asset class
    function computePenaltyForAssetClass(bytes32 _assetClass, uint256 amount) external view returns (uint256) {
        (,, uint256 penBps) = getFeesForAssetClass(_assetClass);
        return (amount * penBps) / 10000;
    }
}
