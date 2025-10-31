# Nova Smart Contracts

Production-ready smart contracts for the Nova protocol - a multi-asset real-world asset (RWA) tokenization platform. Nova enables permissioned ERC-4626 vaults with time-locked tranches, oracle-based NAV, compliance controls, and treasury management for off-chain asset deployment. All contracts are fully upgradeable (UUPS) and comprehensively tested (147 passing tests).

## Architecture Overview

Nova Protocol implements a **multi-asset architecture** where multiple asset classes (Real Estate, Private Equity, etc.) share common infrastructure while maintaining independent vaults with asset-class-specific configurations.

### Key Features

- ✅ **ERC-4626 Compliant Vaults** with oracle-based NAV
- ✅ **Time-Locked Tranches** with 30-day default lockup
- ✅ **Early Redemption Queue** with D+1 settlement and penalties
- ✅ **Multi-Asset Support** via shared infrastructure
- ✅ **Compliance Controls** (global + asset-class-specific eligibility)
- ✅ **Treasury Management** for off-chain business operations
- ✅ **Asset-Class-Specific Fees** (management, performance, penalty)
- ✅ **Fully Upgradeable** (UUPS proxy pattern)
- ✅ **Comprehensive Testing** (147 tests, 100% passing)

## Structure

```
nova-contracts/
├── README.md                      – this file
├── SECURITY_AUDIT_FINDINGS.md    – comprehensive security audit
├── DEPLOYMENT.md                  – deployment guide
├── COPPER_SETUP.md               – secure MCP deployment
├── QUICKREF.md                   – quick reference
├── foundry.toml                  – Foundry configuration
├── src/
│   ├── NovaAssetVault.sol        – ERC-4626 vault with tranches & redemption queue
│   ├── NovaTreasury.sol          – treasury for off-chain asset deployment
│   ├── NovaStablecoinWrapper.sol – multi-stablecoin wrapper (⚠️ has known issues)
│   ├── ComplianceRegistry.sol    – KYC/AML and transfer eligibility
│   ├── MultiAssetNavOracle.sol   – multi-asset NAV oracle with staleness checks
│   ├── FeeModule.sol             – asset-class-specific fee management
│   ├── NovaFactory.sol           – automated vault ecosystem deployment
│   └── interfaces/               – contract interfaces
├── script/
│   ├── Deploy.s.sol              – production deployment script
│   ├── DeployLocal.s.sol         – local development deployment
│   └── PostDeploymentSetup.s.sol – admin operations helper
└── test/
    ├── *.t.sol                   – comprehensive unit tests (147 tests)
    └── EndToEndIntegration.t.sol – full protocol integration test (mainnet fork)
```

## Core Contracts

### NovaAssetVault.sol

Production-ready ERC-4626 vault with advanced features:

- **Asset Class Integration** – each vault represents a specific asset class (Real Estate, Private Equity, etc.)
- **Oracle-Based NAV** – uses `MultiAssetNavOracle` for dynamic share pricing
- **Time-Locked Tranches** – deposits create 30-day locked positions (configurable)
- **Early Redemption Queue** – users can queue early exits with penalties, settled D+1
- **Compliance Gates** – all deposits, redemptions, and transfers checked via `ComplianceRegistry`
- **Treasury Integration** – can transfer idle assets to treasury for off-chain deployment
- **Fee Integration** – automatic fee calculations via `FeeModule`
- **Batch Operations** – efficient processing of multiple redemption requests

**Key Functions:**
```solidity
deposit(uint256 assets, address receiver) → uint256 shares  // Creates locked tranche
queueEarlyRedemption(uint256 shares, address receiver, address owner) → uint256 requestId
processRedemption(uint256 requestId)  // Operator processes queued redemption
redeem(uint256 shares, address receiver, address owner)  // After lock expires
transferToTreasury(uint256 amount)  // Send assets for business operations
```

### NovaTreasury.sol

Treasury contract for managing vault assets deployed off-chain:

- **Asset Tracking** – monitors received, deployed, and returned amounts
- **Deployment Management** – records off-chain deployments with expected returns
- **Vault Authorization** – only authorized vaults can deposit
- **Emergency Mode** – pause and emergency withdrawal capabilities
- **Asset-Class-Specific** – each treasury manages one asset class
- **Compliance Integration** – ensures all destinations are eligible

**Key Functions:**
```solidity
receiveAssets(uint256 amount, string memo)  // Vault deposits assets
deployAssets(uint256 amount, address destination, string purpose, uint256 expectedReturn)
recordAssetReturn(uint256 deploymentId, uint256 amount)
withdrawToVault(address vault, uint256 amount)
```

### NovaStablecoinWrapper.sol

⚠️ **Critical Security Issues Identified** - See `SECURITY_AUDIT_FINDINGS.md` before using

Multi-stablecoin wrapper token (currently has depeg arbitrage vulnerability):

- **Multi-Stablecoin Support** – can accept multiple stablecoins (USDC, USDT, DAI)
- **Decimal Normalization** – converts between different decimal precisions
- **1:1 Wrapping** – assumes all stablecoins maintain $1.00 peg (⚠️ vulnerability)
- **Emergency Withdrawal** – admin can withdraw in emergency (⚠️ breaks backing)

**⚠️ Known Issues:**
1. **Depeg Arbitrage** – attackers can profit when stablecoins lose peg
2. **Decimal Precision Loss** – rounding errors with mixed decimals
3. **Emergency Withdraw** – can create undercollateralization

**Recommended Fix:** Use single stablecoin (USDC only) for MVP, or implement oracle-based pricing.

### ComplianceRegistry.sol

Central compliance and eligibility management:

- **Global Eligibility** – users can be whitelisted globally
- **Asset-Class-Specific Eligibility** – separate eligibility per asset class
- **Flexible Model** – asset classes can use global or dedicated lists
- **Role-Based Access** – compliance operators can manage eligibility
- **Upgradeable** – can add new compliance checks without redeployment

**Key Functions:**
```solidity
setEligible(address user, bool eligible)  // Set global eligibility
setEligibleForAssetClass(bytes32 assetClass, address user, bool eligible)
registerAssetClass(bytes32 assetClass, bool useGlobalEligibility)
isEligibleForAssetClass(bytes32 assetClass, address user) → bool
```

### MultiAssetNavOracle.sol

Multi-asset NAV oracle with staleness detection:

- **Multi-Asset Support** – tracks NAV for multiple asset classes
- **Staleness Checks** – detects outdated NAV data
- **Change Alerts** – emits warnings for large NAV changes
- **Role-Based Updates** – global and asset-class-specific updaters
- **Batch Updates** – efficient updating of multiple asset classes

**Key Functions:**
```solidity
registerAssetClass(bytes32 assetClass, uint256 initialNav, string name)
updateNav(bytes32 assetClass, uint256 newNav)
batchUpdateNav(bytes32[] assetClasses, uint256[] navs)
getNav(bytes32 assetClass) → uint256
isNavFresh(bytes32 assetClass) → bool
```

**Configuration:**
- Staleness threshold: 24 hours (configurable)
- Change threshold: 10% (emits warning if exceeded)

### FeeModule.sol

Asset-class-specific fee management:

- **Management Fees** – annual percentage fee on AUM
- **Performance Fees** – percentage of gains above high water mark
- **Early Redemption Penalties** – fee for exiting before lock expires
- **Asset-Class-Specific** – different fees per asset class
- **Flexible Recipients** – separate recipients per fee type
- **Global Defaults** – fallback to global fees if not configured

**Key Functions:**
```solidity
setFeesForAssetClass(bytes32 assetClass, uint256 mgmtBps, uint256 perfBps, uint256 penaltyBps)
setRecipientsForAssetClass(bytes32 assetClass, address mgmt, address perf, address penalty)
computeManagementFeeForAssetClass(bytes32 assetClass, uint256 totalAssets, uint256 timeElapsed, uint256 yearSeconds) → uint256
computePerformanceFeeForAssetClass(bytes32 assetClass, uint256 gain) → uint256
computePenaltyForAssetClass(bytes32 assetClass, uint256 amount) → uint256
```

**Example Configuration:**
- Real Estate: 1% management, 20% performance, 5% penalty
- Private Equity: 1.5% management, 25% performance, 7% penalty

### NovaFactory.sol

Automated deployment of vault ecosystems:

- **One-Click Deployment** – deploys vault + treasury + configuration
- **Shared Infrastructure** – uses common compliance, oracle, fee module, wrapper
- **Role Management** – automatically grants and transfers roles
- **Batch Deployment** – deploy multiple ecosystems in one transaction
- **Infrastructure Updates** – can update shared components

**Key Functions:**
```solidity
deployVaultEcosystem(bytes32 assetClass, VaultConfig config, uint256 initialNav) → (address vault, address treasury)
batchDeployEcosystems(bytes32[] assetClasses, VaultConfig[] configs, uint256[] initialNavs)
updateSharedInfrastructure(string component, address newAddress)
```

## Multi-Asset Architecture

The protocol uses a **shared infrastructure model** where multiple asset classes share common components:

```
┌─────────────────────────────────────────────────────────┐
│                  Shared Infrastructure                   │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌──────┐│
│  │ Compliance │ │   Oracle   │ │ FeeModule  │ │Wrapper││
│  └────────────┘ └────────────┘ └────────────┘ └──────┘│
└─────────────────────────────────────────────────────────┘
              │                          │
    ┌─────────┴──────────┐    ┌─────────┴──────────┐
    │  Real Estate       │    │  Private Equity    │
    │  ┌──────────────┐  │    │  ┌──────────────┐  │
    │  │    Vault     │  │    │  │    Vault     │  │
    │  └──────────────┘  │    │  └──────────────┘  │
    │  ┌──────────────┐  │    │  ┌──────────────┐  │
    │  │   Treasury   │  │    │  │   Treasury   │  │
    │  └──────────────┘  │    │  └──────────────┘  │
    └────────────────────┘    └────────────────────┘
```

**Benefits:**
- 💰 **Gas Efficiency** – shared contracts reduce deployment costs
- 🔧 **Easy Upgrades** – update compliance logic once for all vaults
- 🎯 **Flexible Configuration** – per-asset-class fees, eligibility, NAV
- 📊 **Centralized Monitoring** – single oracle for all NAV data

## Installing Dependencies

The contracts are built with [Foundry](https://github.com/foundry-rs/foundry) and use [OpenZeppelin Contracts](https://openzeppelin.com/contracts/) for secure, audited base implementations.

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
forge --version
```

### Install Project Dependencies

```bash
# Clone the repository
git clone https://github.com/EmmanuelAmodu/nova-contracts.git
cd nova-contracts

# Install dependencies (OpenZeppelin contracts)
forge install

# Build contracts
forge build

# Run tests
forge test
```

### Dependencies Installed

- `openzeppelin-contracts` - Core ERC standards and utilities
- `openzeppelin-contracts-upgradeable` - Upgradeable contract patterns
- `openzeppelin-foundry-upgrades` - Foundry upgrade helpers
- `forge-std` - Foundry testing utilities

## Testing

The project has comprehensive test coverage with **147 passing tests** across 7 test suites, covering all core functionality, edge cases, and integration scenarios.

### Run Tests

```bash
# Run all tests
forge test

# Run with detailed output
forge test -vvv

# Run with gas reporting
forge test --gas-report

# Run specific test contract
forge test --match-contract ComplianceRegistryTest

# Run specific test function
forge test --match-test testDeposit

# Run with coverage report
forge coverage
```

### Test Coverage by Contract

| Contract | Tests | Coverage | Status |
|----------|-------|----------|--------|
| **ComplianceRegistry** | 21 tests | ✅ Full | initialization, eligibility, asset classes, roles, upgrades |
| **FeeModule** | 16 tests | ✅ Full | fee calculations, recipients, asset-class configs, upgrades |
| **MultiAssetNavOracle** | 20 tests | ✅ Full | NAV updates, staleness, thresholds, batch ops, upgrades |
| **NovaStablecoinWrapper** | 33 tests | ✅ Full | wrap/unwrap, multi-stablecoin, decimals, emergency, upgrades |
| **NovaTreasury** | 11 tests | ✅ Full | asset flows, deployments, withdrawals, emergency, upgrades |
| **NovaAssetVault** | 26 tests | ✅ Full | deposits, redemptions, tranches, queue, treasury, upgrades |
| **NovaFactory** | 20 tests | ✅ Full | deployment, configuration, batch ops, infrastructure updates |

**Total: 147/147 tests passing (100%)**

### End-to-End Integration Tests

The repository includes comprehensive E2E tests that simulate real-world usage:

```bash
# Run E2E tests (requires mainnet RPC URL in .env)
forge test --match-contract EndToEndIntegration -vv
```

**E2E Test Phases:**
1. **User Deposits** - Multiple users deposit into different asset classes
2. **NAV Updates** - Simulate 90-day period with NAV appreciation
3. **Normal Redemption** - Users redeem after lock period expires
4. **Early Redemption** - Test early exit with penalties and D+1 settlement
5. **Fee Computation** - Verify management and performance fees
6. **Batch Operations** - Test batch processing of redemption queues

See [`test/E2E_README.md`](./test/E2E_README.md) for detailed E2E testing documentation.

### Test Features

✅ **Comprehensive Coverage** - All functions, modifiers, and edge cases tested  
✅ **Upgradability Tests** - Verify UUPS upgrades maintain state  
✅ **Access Control Tests** - Verify role-based permissions  
✅ **Integration Tests** - Test contract interactions  
✅ **Mainnet Fork Tests** - Test with real USDC on forked mainnet  
✅ **Gas Optimization** - Gas reports identify optimization opportunities

## Deployment

Nova Protocol supports multiple deployment methods for different security and operational requirements.

### 🚀 Quick Start (Local Development)

```bash
# Start local testnet
anvil

# Deploy with test setup  
forge script script/DeployLocal.s.sol:DeployLocal \
  --rpc-url http://localhost:8545 \
  --broadcast
```

This deploys all contracts, sets up test users, and configures sample asset classes.

### 🧪 Testnet Deployment

```bash
# Configure environment
cp .env.example .env
# Edit .env with your RPC URL and private key

# Deploy to Sepolia
forge script script/Deploy.s.sol:DeployNova \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast --verify

# Deploy to Goerli
forge script script/Deploy.s.sol:DeployNova \
  --rpc-url $GOERLI_RPC_URL \
  --broadcast --verify
```

### 🔐 Production Deployment (Copper MCP - Recommended)

**Secure, keyless deployment using Copper MCP for institutional-grade security:**

1. **Setup Copper MCP** following [`COPPER_SETUP.md`](./COPPER_SETUP.md)
2. **Configure GitHub Secrets** with Copper credentials and network config
3. **Deploy via GitHub Actions**:
   - Go to Actions → "Deploy Nova Contracts"
   - Select environment (mainnet/testnet) and branch
   - Click "Run workflow" 
4. **Approve via Copper Dashboard** when prompted for multi-sig approval

**Benefits:**
- 🔒 **No Private Keys** - Complete elimination of private key exposure
- 👥 **Multi-Signature** - Requires multiple approvals for security
- 📊 **Audit Trail** - Full transaction history and approval tracking
- ⚡ **Automated** - CI/CD integration with secure signing
- 🛡️ **Institutional Grade** - Used by major DeFi protocols

### Post-Deployment Operations

After deploying, use the `PostDeploymentSetup.s.sol` script for common operations:

```bash
# Set user eligibility
forge script script/PostDeploymentSetup.s.sol:PostDeploymentSetup \
  --sig "setMultipleEligible(address,address[])" \
  $COMPLIANCE_ADDRESS "[$USER1,$USER2,$USER3]" \
  --rpc-url $RPC_URL --broadcast

# Update NAV for asset class
forge script script/PostDeploymentSetup.s.sol:PostDeploymentSetup \
  --sig "updateAssetClassNav(address,bytes32,uint256)" \
  $ORACLE_ADDRESS $ASSET_CLASS $NEW_NAV \
  --rpc-url $RPC_URL --broadcast

# Configure fees for asset class
forge script script/PostDeploymentSetup.s.sol:PostDeploymentSetup \
  --sig "configureAssetClassFees(address,bytes32,uint256,uint256,uint256)" \
  $FEE_MODULE_ADDRESS $ASSET_CLASS 100 2000 500 \
  --rpc-url $RPC_URL --broadcast

# Deploy new vault ecosystem
forge script script/PostDeploymentSetup.s.sol:PostDeploymentSetup \
  --sig "deployVaultEcosystem(address,bytes32,string,string,address,uint256)" \
  $FACTORY_ADDRESS $ASSET_CLASS "Vault Name" "SYMBOL" $ASSET_ADDRESS $INITIAL_NAV \
  --rpc-url $RPC_URL --broadcast
```

### 📚 Deployment Documentation

- 📖 [**DEPLOYMENT.md**](./DEPLOYMENT.md) - Comprehensive deployment guide with step-by-step instructions
- 🔐 [**COPPER_SETUP.md**](./COPPER_SETUP.md) - Secure MCP deployment setup and configuration
- 🚀 [**QUICKREF.md**](./QUICKREF.md) - Quick reference for common commands and operations

### ⚠️ Security Requirements

**For Production Deployments:**

1. ✅ **Use Copper MCP or Hardware Wallets** - Never use private keys in production
2. ✅ **Multi-Signature Setup** - Require multiple approvals for critical operations
3. ✅ **Verify Contracts** - Always verify on Etherscan/block explorer
4. ✅ **Test on Testnet First** - Deploy and test on Sepolia/Goerli before mainnet
5. ✅ **Security Audit** - Complete professional audit before mainnet deployment
6. ✅ **Monitoring Setup** - Configure alerting for critical events
7. ✅ **Incident Response Plan** - Document emergency procedures

**⚠️ NEVER commit private keys, mnemonics, or sensitive credentials to version control.**

## Security

### 🔒 Security Audit

A comprehensive security audit has been performed identifying **13 issues** across the protocol:

- 🔴 **2 Critical** - Stablecoin depeg arbitrage and decimal precision vulnerabilities
- 🟠 **4 High** - Emergency withdraw, NAV staleness, reentrancy, treasury sync issues
- 🟡 **4 Medium** - NAV change limits, queue griefing, slippage protection, batch atomicity
- 🟢 **2 Low** - Missing events, overflow checks
- 🔵 **1 Informational** - Code quality improvements

**Full audit report:** [`SECURITY_AUDIT_FINDINGS.md`](./SECURITY_AUDIT_FINDINGS.md)

### ⚠️ Critical Findings

#### NovaStablecoinWrapper Has Known Vulnerabilities

The multi-stablecoin wrapper has two critical issues:

1. **Depeg Arbitrage Attack** - Attackers can profit when stablecoins depeg by depositing depegged assets and withdrawing healthy ones
2. **Decimal Precision Loss** - Mixing 6-decimal (USDC) and 18-decimal (DAI) tokens creates rounding errors and arbitrage opportunities

**Recommended Fix:** Use **single stablecoin only (USDC)** for MVP/production until oracle-based pricing is implemented.

### Security Best Practices

#### For Developers

- ✅ Run full test suite before deployments: `forge test`
- ✅ Check for compiler warnings: `forge build --force`
- ✅ Review gas usage: `forge test --gas-report`
- ✅ Run static analysis: `slither .`
- ✅ Test on forked mainnet before deploying
- ✅ Use deployment checklists from `DEPLOYMENT.md`

#### For Production

- 🔐 **Multi-Signature Required** - Use Gnosis Safe or Copper MCP
- 🔑 **Hardware Wallets** - Never use hot wallets for admin keys
- 📊 **Monitoring** - Set up alerts for critical events
- 🚨 **Incident Response** - Document and test emergency procedures
- 🔄 **Upgrade Process** - Test upgrades on testnet first
- 📝 **Audit Before Mainnet** - Professional security audit required

### Upgradability

All contracts use the **UUPS (Universal Upgradeable Proxy Standard)** pattern:

- ✅ **Transparent Upgrades** - Clear separation of proxy and implementation
- ✅ **Access Control** - Only `DEFAULT_ADMIN_ROLE` can upgrade
- ✅ **State Preservation** - Upgrades maintain contract state
- ✅ **Tested** - All contracts have upgrade tests

**Upgrade Process:**
```solidity
// Deploy new implementation
NewImplementation newImpl = new NewImplementation();

// Upgrade via proxy (requires admin role)
UUPSUpgradeable(proxyAddress).upgradeToAndCall(
    address(newImpl),
    "" // Optional initialization data
);
```

### Bug Bounty

We encourage responsible disclosure of security vulnerabilities:

- 📧 **Contact:** security@nova-protocol.io
- 💰 **Rewards:** Based on severity (Critical: $10k+, High: $5k+, Medium: $1k+)
- ⏱️ **Response Time:** 24-48 hours for initial response
- 🤝 **Recognition:** Public acknowledgment (with permission)

### Audit History

| Date | Auditor | Scope | Report |
|------|---------|-------|--------|
| Oct 2025 | Internal | All contracts | [SECURITY_AUDIT_FINDINGS.md](./SECURITY_AUDIT_FINDINGS.md) |
| Pending | External | Pre-mainnet audit | TBD |

## Known Issues & Limitations

### Current Limitations

1. **NovaStablecoinWrapper** - Has critical depeg/decimal issues (use single stablecoin)
2. **NAV Updates** - Manual process, requires off-chain oracle operator
3. **No Flash Loan Protection** - Vaults may be vulnerable to flash loan attacks
4. **Limited Governance** - Admin roles are centralized (plan for DAO governance)
5. **No Emergency Pause** - Individual vaults can pause, but no protocol-wide pause

### Planned Improvements

- [ ] Implement oracle-based stablecoin pricing (Chainlink)
- [ ] Add automated NAV updates via keeper network
- [ ] Flash loan attack mitigation
- [ ] Decentralized governance implementation (Governor + Timelock)
- [ ] Protocol-wide emergency pause mechanism
- [ ] Cross-chain deployment (Layer 2s)
- [ ] Advanced fee structures (high water mark tracking)

## Example Usage

### Deploying a New Asset Class

```solidity
// 1. Deploy factory and infrastructure (one-time setup)
NovaFactory factory = new NovaFactory();
// ... deploy compliance, oracle, feeModule, wrapper

// 2. Deploy Real Estate vault ecosystem
bytes32 REAL_ESTATE = keccak256("REAL_ESTATE");
NovaFactory.VaultConfig memory config = NovaFactory.VaultConfig({
    vaultName: "Nova Real Estate Vault",
    vaultSymbol: "nREV",
    asset: address(usdcWrapper),
    managementFeeBps: 100,      // 1%
    performanceFeeBps: 2000,    // 20%
    penaltyBps: 500,            // 5%
    managementFeeRecipient: feeRecipient,
    performanceFeeRecipient: feeRecipient,
    emergencyRecipient: admin
});

(address vault, address treasury) = factory.deployVaultEcosystem(
    REAL_ESTATE,
    config,
    1e18  // Initial NAV: $1.00
);
```

### User Deposits & Redemptions

```solidity
// User deposits into vault
usdc.approve(address(wrapper), 100_000e6);
wrapper.wrap(address(usdc), 100_000e6);  // Get wrapper tokens

wrapper.approve(address(vault), 100_000e18);
uint256 shares = vault.deposit(100_000e18, user);  // Get vault shares
// Shares locked for 30 days by default

// After lock period: Normal redemption
uint256 assets = vault.redeem(shares, user, user);

// Before lock expires: Queue early redemption (D+1 settlement)
uint256 requestId = vault.queueEarlyRedemption(shares, user, user);
// Operator processes after settlement date
vault.processRedemption(requestId);  // User receives assets minus penalty
```

### Admin Operations

```solidity
// Set user eligibility
compliance.setEligible(user, true);

// Update NAV (daily)
oracle.updateNav(REAL_ESTATE, 1.05e18);  // 5% appreciation

// Batch update multiple asset classes
bytes32[] memory assetClasses = new bytes32[](2);
assetClasses[0] = REAL_ESTATE;
assetClasses[1] = PRIVATE_EQUITY;

uint256[] memory navs = new uint256[](2);
navs[0] = 1.05e18;
navs[1] = 1.12e18;

oracle.batchUpdateNav(assetClasses, navs);

// Transfer vault assets to treasury for deployment
vault.transferToTreasury(500_000e18);

// Treasury deploys assets
treasury.deployAssets(
    500_000e18,
    businessPartner,
    "Real estate acquisition",
    550_000e18  // Expected return
);
```

## Contributing

We welcome contributions! Please follow these guidelines:

### Development Setup

```bash
# Fork and clone the repository
git clone https://github.com/YOUR_USERNAME/nova-contracts.git
cd nova-contracts

# Install dependencies
forge install

# Create a feature branch
git checkout -b feature/your-feature-name

# Make your changes and test
forge test

# Submit a pull request
```

### Contribution Guidelines

- ✅ Write tests for all new features
- ✅ Ensure all tests pass: `forge test`
- ✅ Follow Solidity style guide
- ✅ Add NatSpec comments for public functions
- ✅ Update documentation as needed
- ✅ Keep PRs focused and small
- ✅ Reference issues in commit messages

### Code Style

Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html):

```solidity
// ✅ Good
function depositAssets(uint256 amount, address receiver) 
    external 
    whenNotPaused 
    returns (uint256 shares) 
{
    require(amount > 0, "Zero amount");
    // Implementation
}

// ❌ Bad
function depositAssets(uint256 amount,address receiver) external whenNotPaused returns(uint256 shares){require(amount>0,"Zero amount");
// Implementation
}
```

## License

This project is licensed under the **MIT License** - see the [LICENSE](./LICENSE) file for details.

<!-- ## Support & Community

- 📧 **Email:** support@nova-protocol.io
- 💬 **Discord:** [discord.gg/nova-protocol](https://discord.gg/nova-protocol)
- 🐦 **Twitter:** [@NovaProtocol](https://twitter.com/NovaProtocol)
- 📚 **Documentation:** [docs.nova-protocol.io](https://docs.nova-protocol.io)
- 🐛 **Issues:** [GitHub Issues](https://github.com/EmmanuelAmodu/nova-contracts/issues) -->

## Acknowledgments

Built with:
- [Foundry](https://github.com/foundry-rs/foundry) - Blazing fast Ethereum development framework
- [OpenZeppelin Contracts](https://openzeppelin.com/contracts/) - Secure smart contract library
- [Solidity](https://soliditylang.org/) - Contract-oriented programming language

Inspired by:
- [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) - Tokenized vault standard
- [Centrifuge](https://centrifuge.io/) - Real-world asset tokenization
- [Maple Finance](https://maple.finance/) - Institutional DeFi lending

Special thanks to the DeFi and RWA communities for their continued innovation.

---

**⚠️ Disclaimer:** This software is provided "as is" without warranty. The contracts have known security issues documented in `SECURITY_AUDIT_FINDINGS.md`. Professional security audit is required before mainnet deployment. Use at your own risk.