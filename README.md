# Task #1: Describe a scenario or edge case that could lead to an economic attack or failure of any live protocol.

A good example of an economic failure scenario is the Curve stablecoin pool imbalance that happens when one stablecoin loses its peg.

Curve’s AMM assumes all tokens in a pool, let say USDC, USDT, and DAI are worth roughly one dollar. If one of them, like DAI, drops to ninety cents, arbitrageurs will start swapping their depegged DAI for the “good” stablecoins inside the pool.

Because Curve’s invariant still treats them as equal, the pool quickly becomes imbalanced maybe 95% DAI and only 5% USDC/USDT. Liquidity providers are then effectively holding the bad asset, and any protocol that uses those LP tokens as collateral inherits that loss.

We saw this in play during the Terra/UST collapse, where Curve’s pools drained of real stablecoins and accelerated the peg breakdown. It’s not a code exploit, it’s a rational, market-driven attack on the protocol’s economic assumptions.

Defenses against this includes peg monitors, circuit breakers, isolating risky stablecoins, and dynamic pool parameters to adapt to volatility.

# Task #2: Create a small protocol with hidden code or economic vulnerabilities.

## 1. Stablecoin Depeg Arbitrage Attack

**Contract:** `NovaStablecoinWrapper.sol`  
**Location:** Lines 145-195 (`wrap()` and `unwrap()` functions)  
**Severity:** 🔴 Critical

### Description
The wrapper assumes all stablecoins maintain a 1:1 USD peg at all times. This creates a critical arbitrage opportunity when any supported stablecoin depegs.

### Vulnerable Code
```solidity
function wrap(address stablecoin, uint256 amount) external whenNotPaused nonReentrant {
    // ...
    // Normalize amount to 18 decimals for wrapper token
    uint256 wrapperAmount = _normalizeAmount(amount, stablecoins[stablecoin].decimals, 18);
    _mint(msg.sender, wrapperAmount);
    // ❌ No price check - assumes 1 USDC = 1 USDT = 1 DAI = $1.00
}

function unwrap(address stablecoin, uint256 wrapperAmount) external whenNotPaused nonReentrant {
    // ...
    uint256 stablecoinAmount = _normalizeAmount(wrapperAmount, 18, stablecoins[stablecoin].decimals);
    // ❌ No price check - allows conversion at 1:1 regardless of market value
}
```

### Attack Scenario
```
Day 1 - Normal conditions:
- Protocol has: 1M USDC + 1M USDT in reserves
- Total wrapper supply: 2M tokens

Day 2 - USDC depegs to $0.90:
- Attacker wraps 1M USDC ($900k real value)
- Receives 1M wrapper tokens
- Immediately unwraps for 1M USDT ($1M value)
- Profit: $100k
- Protocol loss: 100k USDT reserves drained

Result: Healthy stablecoin reserves depleted, protocol left holding depegged assets
```

### Impact
- **Direct Loss:** Protocol can be drained of healthy stablecoin reserves
- **Systemic Risk:** Can cascade to vault insolvency
- **User Loss:** Legitimate users left holding depegged assets
- **Estimated Loss:** Up to 100% of healthy reserves during severe depeg events

### Proof of Concept
```solidity
// Attacker contract
contract DepegArbitrage {
    function exploit(NovaStablecoinWrapper wrapper, address usdc, address usdt) external {
        // Assume USDC depegged to $0.90
        uint256 amount = 1_000_000e6; // 1M USDC
        
        // Step 1: Wrap depegged USDC
        IERC20(usdc).approve(address(wrapper), amount);
        wrapper.wrap(usdc, amount); // Get 1M wrapper tokens for $900k value
        
        // Step 2: Unwrap for healthy USDT
        wrapper.unwrap(usdt, 1_000_000e18); // Get 1M USDT worth $1M
        
        // Profit: $100k in one transaction
    }
}
```

### Recommendations

**Option 1: Oracle-Based Pricing (Recommended for Production)**
```solidity
// Add Chainlink price feed integration
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

mapping(address => AggregatorV3Interface) public priceFeeds;
uint256 public constant PRICE_TOLERANCE = 200; // 2% deviation allowed (200 bps)

function wrap(address stablecoin, uint256 amount) external {
    uint256 price = _getPrice(stablecoin);
    require(price >= 1e8 - PRICE_TOLERANCE, "Stablecoin depegged");
    
    // Mint based on actual USD value
    uint256 usdValue = (amount * price) / 1e8;
    uint256 wrapperAmount = _normalizeAmount(usdValue, stablecoins[stablecoin].decimals, 18);
    _mint(msg.sender, wrapperAmount);
}

function _getPrice(address stablecoin) internal view returns (uint256) {
    AggregatorV3Interface feed = priceFeeds[stablecoin];
    (, int256 price,,,) = feed.latestRoundData();
    require(price > 0, "Invalid price");
    return uint256(price);
}
```

**Option 2: Single Stablecoin**
```solidity
// Only support one primary stablecoin (e.g., USDC)
// Remove multi-stablecoin functionality entirely
// Wrapper = 1:1 with USDC only
```

**Option 3: Circuit Breaker**
```solidity
// Detect and halt during depeg events
uint256 public constant DEPEG_THRESHOLD = 200; // 2%

function wrap(address stablecoin, uint256 amount) external {
    uint256 price = _getPrice(stablecoin);
    uint256 deviation = price > 1e8 ? price - 1e8 : 1e8 - price;
    
    if (deviation > DEPEG_THRESHOLD) {
        // Apply haircut or pause deposits
        revert("Stablecoin depegged - deposits paused");
    }
    // ... continue wrap
}
```

---

## 2. Decimal Precision Loss and Manipulation

**Contract:** `NovaStablecoinWrapper.sol`  
**Location:** Lines 277-288 (`_normalizeAmount()` function)  
**Severity:** 🔴 Critical

### Description
The decimal normalization function can cause precision loss and enable manipulation when converting between stablecoins with different decimal places.

### Vulnerable Code
```solidity
function _normalizeAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
    if (fromDecimals == toDecimals) {
        return amount;
    } else if (fromDecimals > toDecimals) {
        return amount / (10 ** (fromDecimals - toDecimals));  // ❌ Truncation loss
    } else {
        return amount * (10 ** (toDecimals - fromDecimals));  // ❌ Potential overflow
    }
}
```

### Problems

**Problem 1: Rounding Down Causes Value Loss**
```solidity
// User wraps 0.000001 wrapper token (1 wei at 18 decimals)
// Converting to USDC (6 decimals):
uint256 usdcAmount = 1 / (10 ** 12); // = 0 (rounds down!)
// User loses value, can't unwrap small amounts
```

**Problem 2: Mixed Decimals Create Reserve Mismatch**
```solidity
Scenario:
1. User A deposits 1000 DAI (18 decimals) → gets 1000e18 wrapper
2. User B deposits 1000 USDC (6 decimals) → gets 1000e18 wrapper
3. Total: 2000e18 wrapper backed by 1000 DAI + 1000 USDC
4. User A unwraps 1000e18 for USDC → gets 1000e6 USDC ✓
5. User B tries to unwrap 1000e18 for DAI → wants 1000e18 DAI
6. But reserves only have 1000e18 DAI ✓
7. Works IF 1:1 peg holds, but creates arbitrage opportunity if DAI depegs
```

**Problem 3: Dust Accumulation**
```solidity
// Repeatedly wrapping/unwrapping small amounts loses dust
for (uint i = 0; i < 1000; i++) {
    wrapper.wrap(usdc, 1);       // 1 unit of USDC
    wrapper.unwrap(usdc, 1e12);  // Converts to 1 USDC, loses remainder
}
// Accumulated loss: up to 1000 wei per iteration
```

### Impact
- **Value Loss:** Users lose value on small amounts due to rounding
- **Arbitrage:** Mixed decimal stablecoins enable cross-token arbitrage
- **Reserve Drain:** Dust and rounding errors compound over time
- **Gas Griefing:** Attackers can exploit rounding in loops

### Recommendations

**Solution 1: Enforce Minimum Amounts**
```solidity
uint256 public constant MIN_WRAP_AMOUNT = 1e6; // 1 USDC / 0.000001 DAI

function wrap(address stablecoin, uint256 amount) external {
    require(amount >= MIN_WRAP_AMOUNT, "Amount too small");
    // ... rest of function
}
```

**Solution 2: Use Wrapper Decimals Matching Primary Stablecoin**
```solidity
// If primary stablecoin is USDC (6 decimals), make wrapper 6 decimals
function initialize(address usdc, address admin) public initializer {
    __ERC20_init("Nova Wrapper", "NOWRAP");
    // ❌ Current: Uses 18 decimals by default
    // ✅ Better: Match USDC decimals
}

// Override decimals()
function decimals() public view virtual override returns (uint8) {
    return 6; // Match USDC
}
```

**Solution 3: Round Up on Unwrap (Favor Protocol)**
```solidity
function _normalizeAmount(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
    if (fromDecimals == toDecimals) {
        return amount;
    } else if (fromDecimals > toDecimals) {
        uint256 divisor = 10 ** (fromDecimals - toDecimals);
        // Round down on wrap (more wrapper tokens)
        return amount / divisor;
    } else {
        // Check for overflow
        uint256 multiplier = 10 ** (toDecimals - fromDecimals);
        require(amount <= type(uint256).max / multiplier, "Overflow");
        return amount * multiplier;
    }
}
```

---