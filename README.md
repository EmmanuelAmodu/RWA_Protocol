# Task #1: Describe a scenario or edge case that could lead to an economic attack or failure of any live protocol.

A good example of an economic failure scenario is the Curve stablecoin pool imbalance that happens when one stablecoin loses its peg.

Curve’s AMM assumes all tokens in a pool, let say USDC, USDT, and DAI are worth roughly one dollar. If one of them, like DAI, drops to ninety cents, arbitrageurs will start swapping their depegged DAI for the “good” stablecoins inside the pool.

Because Curve’s invariant still treats them as equal, the pool quickly becomes imbalanced maybe 95% DAI and only 5% USDC/USDT. Liquidity providers are then effectively holding the bad asset, and any protocol that uses those LP tokens as collateral inherits that loss.

We saw this in play during the Terra/UST collapse, where Curve’s pools drained of real stablecoins and accelerated the peg breakdown. It’s not a code exploit, it’s a rational, market-driven attack on the protocol’s economic assumptions.

Defenses against this includes peg monitors, circuit breakers, isolating risky stablecoins, and dynamic pool parameters to adapt to volatility.

# Task #2: Create a small protocol with hidden code or economic vulnerabilities.

## Stablecoin Depeg Arbitrage Attack

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
    // No price check - assumes 1 USDC = 1 USDT = 1 DAI = $1.00
}

function unwrap(address stablecoin, uint256 wrapperAmount) external whenNotPaused nonReentrant {
    // ...
    uint256 stablecoinAmount = _normalizeAmount(wrapperAmount, 18, stablecoins[stablecoin].decimals);
    // No price check - allows conversion at 1:1 regardless of market value
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

