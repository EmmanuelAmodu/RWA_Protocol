// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title NovaStablecoinWrapper
 * @notice ERC20 wrapper token that can be backed by multiple supported stablecoins
 * @dev Users can mint wrapper tokens by depositing supported stablecoins and redeem
 *      wrapper tokens for any available supported stablecoin. Upgradeable using UUPS pattern.
 */
contract NovaStablecoinWrapper is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Role definitions
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Supported stablecoin information
    struct StablecoinInfo {
        bool isSupported; // Still in the system
        bool isEnabled; // Can accept new deposits
        uint256 totalDeposited;
        uint256 currentBalance;
        uint8 decimals;
    }

    // State variables
    mapping(address => StablecoinInfo) public stablecoins;
    EnumerableSet.AddressSet private _supportedStablecoins;

    // Events
    event StablecoinAdded(address indexed stablecoin, uint8 decimals);
    event StablecoinRemoved(address indexed stablecoin);
    event StablecoinStatusChanged(address indexed stablecoin, bool isEnabled);
    event Wrapped(address indexed user, address indexed stablecoin, uint256 stablecoinAmount, uint256 wrapperAmount);
    event Unwrapped(address indexed user, address indexed stablecoin, uint256 wrapperAmount, uint256 stablecoinAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param name Token name
     * @param symbol Token symbol
     * @param admin Admin address
     */
    function initialize(string memory name, string memory symbol, address admin) public initializer {
        require(admin != address(0), "NovaStablecoinWrapper: zero admin address");

        __ERC20_init(name, symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ASSET_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /**
     * @notice Authorize upgrade (only admin)
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Add a new supported stablecoin
     * @param stablecoin Address of the stablecoin to add
     */
    function addStablecoin(address stablecoin) external onlyRole(ASSET_MANAGER_ROLE) {
        require(stablecoin != address(0), "NovaStablecoinWrapper: zero address");
        require(!stablecoins[stablecoin].isSupported, "NovaStablecoinWrapper: already supported");

        uint8 decimals = IERC20Metadata(stablecoin).decimals();

        stablecoins[stablecoin] = StablecoinInfo({
            isSupported: true, isEnabled: true, totalDeposited: 0, currentBalance: 0, decimals: decimals
        });

        // Add to enumerable set
        require(_supportedStablecoins.add(stablecoin), "NovaStablecoinWrapper: failed to add");

        emit StablecoinAdded(stablecoin, decimals);
    }

    /**
     * @notice Enable or disable deposits for a stablecoin
     * @param stablecoin Address of the stablecoin
     * @param enabled Whether deposits should be enabled
     * @dev Disabling is the first step before removing a stablecoin. This prevents new deposits
     *      while allowing existing holders to unwrap, eventually reaching zero balance for removal.
     */
    function setStablecoinEnabled(address stablecoin, bool enabled) external onlyRole(ASSET_MANAGER_ROLE) {
        require(stablecoins[stablecoin].isSupported, "NovaStablecoinWrapper: not supported");
        require(stablecoins[stablecoin].isEnabled != enabled, "NovaStablecoinWrapper: already in desired state");

        stablecoins[stablecoin].isEnabled = enabled;
        emit StablecoinStatusChanged(stablecoin, enabled);
    }

    /**
     * @notice Remove support for a stablecoin
     * @param stablecoin Address of the stablecoin to remove
     * @dev Requires the stablecoin to be disabled first and have zero balance
     */
    function removeStablecoin(address stablecoin) external onlyRole(ASSET_MANAGER_ROLE) {
        require(stablecoins[stablecoin].isSupported, "NovaStablecoinWrapper: not supported");
        require(!stablecoins[stablecoin].isEnabled, "NovaStablecoinWrapper: must disable first");
        require(stablecoins[stablecoin].currentBalance == 0, "NovaStablecoinWrapper: balance not zero");

        stablecoins[stablecoin].isSupported = false;

        // Remove from enumerable set (O(1) operation)
        require(_supportedStablecoins.remove(stablecoin), "NovaStablecoinWrapper: failed to remove");

        emit StablecoinRemoved(stablecoin);
    }

    /**
     * @notice Wrap stablecoins to receive wrapper tokens (1:1 ratio)
     * @param stablecoin Address of the stablecoin to deposit
     * @param amount Amount of stablecoin to wrap
     */
    function wrap(address stablecoin, uint256 amount) external whenNotPaused nonReentrant {
        require(stablecoins[stablecoin].isSupported, "NovaStablecoinWrapper: stablecoin not supported");
        require(stablecoins[stablecoin].isEnabled, "NovaStablecoinWrapper: deposits disabled");
        require(amount > 0, "NovaStablecoinWrapper: zero amount");

        // Transfer stablecoin from user
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), amount);

        // Update tracking
        stablecoins[stablecoin].totalDeposited += amount;
        stablecoins[stablecoin].currentBalance += amount;

        // Normalize amount to 18 decimals for wrapper token
        uint256 wrapperAmount = _normalizeAmount(amount, stablecoins[stablecoin].decimals, 18);

        // Mint wrapper tokens to user
        _mint(msg.sender, wrapperAmount);

        emit Wrapped(msg.sender, stablecoin, amount, wrapperAmount);
    }

    /**
     * @notice Unwrap wrapper tokens to receive stablecoins
     * @param stablecoin Address of the stablecoin to receive
     * @param wrapperAmount Amount of wrapper tokens to burn
     */
    function unwrap(address stablecoin, uint256 wrapperAmount) external whenNotPaused nonReentrant {
        require(stablecoins[stablecoin].isSupported, "NovaStablecoinWrapper: stablecoin not supported");
        require(wrapperAmount > 0, "NovaStablecoinWrapper: zero amount");
        require(balanceOf(msg.sender) >= wrapperAmount, "NovaStablecoinWrapper: insufficient balance");

        // Convert wrapper amount to stablecoin amount
        uint256 stablecoinAmount = _normalizeAmount(wrapperAmount, 18, stablecoins[stablecoin].decimals);

        require(
            stablecoins[stablecoin].currentBalance >= stablecoinAmount,
            "NovaStablecoinWrapper: insufficient stablecoin reserves"
        );

        // Burn wrapper tokens
        _burn(msg.sender, wrapperAmount);

        // Update tracking
        stablecoins[stablecoin].currentBalance -= stablecoinAmount;

        // Transfer stablecoin to user
        IERC20(stablecoin).safeTransfer(msg.sender, stablecoinAmount);

        emit Unwrapped(msg.sender, stablecoin, wrapperAmount, stablecoinAmount);
    }

    /**
     * @notice Emergency withdraw stablecoins (only admin)
     * @param stablecoin Address of the stablecoin to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address stablecoin, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "NovaStablecoinWrapper: zero recipient");
        require(amount > 0, "NovaStablecoinWrapper: zero amount");

        uint256 balance = IERC20(stablecoin).balanceOf(address(this));
        require(balance >= amount, "NovaStablecoinWrapper: insufficient balance");

        IERC20(stablecoin).safeTransfer(to, amount);

        // Update tracking if it's a supported stablecoin
        if (stablecoins[stablecoin].isSupported) {
            stablecoins[stablecoin].currentBalance = balance - amount;
        }
    }

    /**
     * @notice Get list of supported stablecoins
     * @return Array of supported stablecoin addresses
     */
    function getSupportedStablecoins() external view returns (address[] memory) {
        uint256 length = _supportedStablecoins.length();
        address[] memory stablecoins_ = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            stablecoins_[i] = _supportedStablecoins.at(i);
        }

        return stablecoins_;
    }

    /**
     * @notice Get the number of supported stablecoins
     * @return Count of supported stablecoins
     */
    function getSupportedStablecoinsCount() external view returns (uint256) {
        return _supportedStablecoins.length();
    }

    /**
     * @notice Get available balance for a specific stablecoin
     * @param stablecoin Address of the stablecoin
     * @return Available balance for unwrapping
     */
    function getAvailableBalance(address stablecoin) external view returns (uint256) {
        return stablecoins[stablecoin].currentBalance;
    }

    /**
     * @notice Check if a stablecoin is supported
     * @param stablecoin Address of the stablecoin to check
     * @return True if supported
     */
    function isStablecoinSupported(address stablecoin) external view returns (bool) {
        return stablecoins[stablecoin].isSupported;
    }

    /**
     * @notice Get total wrapper tokens that can be redeemed for a specific stablecoin
     * @param stablecoin Address of the stablecoin
     * @return Amount of wrapper tokens redeemable
     */
    function getRedeemableAmount(address stablecoin) external view returns (uint256) {
        if (!stablecoins[stablecoin].isSupported) {
            return 0;
        }

        uint256 stablecoinBalance = stablecoins[stablecoin].currentBalance;
        return _normalizeAmount(stablecoinBalance, stablecoins[stablecoin].decimals, 18);
    }

    /**
     * @notice Normalize amount between different decimal precisions
     * @param amount Amount to normalize
     * @param fromDecimals Current decimal precision
     * @param toDecimals Target decimal precision
     * @return Normalized amount
     */
    function _normalizeAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
