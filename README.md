# PolyLend

A decentralized lending protocol that enables Polymarket traders to borrow USDC against their conditional token (ERC-1155) positions.

## Overview

PolyLend allows users to:
- **Lenders**: Deposit USDC to earn yield from borrower interest
- **Borrowers**: Use Polymarket conditional tokens as collateral to borrow USDC
- **Liquidators**: Liquidate unhealthy positions and earn a bonus

## Key Features

- **Time-Decay LTV**: Loan-to-value ratio decreases as markets approach resolution
- **TWAP Oracle**: 30-minute time-weighted average price with circuit breaker protection
- **Risk Management**: Pre-resolution freeze, manual market freeze, and global emergency pause
- **Liquidation Engine**: Health factor monitoring with configurable bonus incentives

## MVP Parameters

| Parameter | Value |
|-----------|-------|
| Max LTV (normal, >7 days) | 50% |
| Max LTV (medium risk, 2-7 days) | 35% |
| Max LTV (high risk, 24-48h) | 20% |
| Pre-Resolution Freeze | <24 hours |
| Liquidation Threshold | 75% |
| Liquidation Bonus | 10% |
| Close Factor | 50% |
| TWAP Window | 30 minutes |
| Circuit Breaker | 8% deviation |
| Staleness Threshold | 5 minutes |

## Project Structure

```
polylend/
├── foundry.toml
├── remappings.txt
├── script/
│   └── Deploy.s.sol
├── src/
│   ├── PolyLend.sol                    # Main entry point
│   ├── core/
│   │   ├── LendingPool.sol             # USDC deposits/withdrawals
│   │   ├── Vault.sol                   # ERC-1155 collateral custody
│   │   └── LiquidationEngine.sol       # Health factor & liquidations
│   ├── oracle/
│   │   └── PolymarketTWAPOracle.sol    # 30-min TWAP oracle
│   ├── risk/
│   │   ├── LTVCalculator.sol           # Time-decay LTV logic
│   │   ├── CircuitBreaker.sol          # Emergency pause & freeze
│   │   └── MarketRegistry.sol          # Market metadata
│   ├── interfaces/
│   │   └── *.sol                       # All interfaces
│   └── libraries/
│       ├── DataTypes.sol               # Core structs
│       ├── Errors.sol                  # Custom errors
│       └── PercentageMath.sol          # Basis point math
└── test/
    ├── unit/                           # Unit tests
    ├── integration/                    # Integration tests
    └── mocks/                          # Mock contracts
```

## Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Setup

```bash
# Clone the repository
git clone <repo-url>
cd polylend

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build
forge build

# Test
forge test

# Test with verbosity
forge test -vvv
```

## Deployment

### Local Testing

```bash
# Start local node
anvil

# Deploy (in another terminal)
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Polygon Mainnet

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export POLYGON_RPC_URL=your_rpc_url

# Deploy
forge script script/Deploy.s.sol --rpc-url $POLYGON_RPC_URL --broadcast --verify
```

## Usage

### For Lenders

```solidity
// Approve USDC
usdc.approve(address(lendingPool), amount);

// Deposit USDC
lendingPool.deposit(amount);

// Withdraw (burns shares)
lendingPool.withdraw(shares);
```

### For Borrowers

```solidity
// Approve CTF tokens
ctf.setApprovalForAll(address(polyLend), true);

// Deposit collateral
polyLend.depositCollateral(tokenId, amount, marketId);

// Borrow USDC
polyLend.borrow(tokenId, borrowAmount);

// Repay loan
usdc.approve(address(polyLend), repayAmount);
polyLend.repay(tokenId, repayAmount);

// Withdraw collateral (when no debt or health factor allows)
polyLend.withdrawCollateral(tokenId, amount);
```

### For Liquidators

```solidity
// Check if liquidatable
bool canLiquidate = polyLend.isLiquidatable(borrower, tokenId);

// Get max liquidation amounts
(uint256 maxRepay, uint256 maxSeize) = liquidationEngine.getMaxLiquidation(borrower, tokenId);

// Execute liquidation
usdc.approve(address(liquidationEngine), repayAmount);
uint256 seized = polyLend.liquidate(borrower, tokenId, repayAmount);
```

## External Dependencies

**OpenZeppelin Contracts:**
- `Ownable`, `Pausable`, `ReentrancyGuard`
- `ERC1155Holder`, `IERC20`, `IERC1155`, `SafeERC20`

**Polymarket (Polygon Mainnet):**
- Conditional Tokens: `0x4D97DCd97eC945f40cF65F87097ACe5EA0476045`
- USDC: `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`

## Security Considerations

- ReentrancyGuard on all external state-changing functions
- CEI (Checks-Effects-Interactions) pattern throughout
- Oracle staleness checks before any price-dependent operation
- Separate tx required for deposit + borrow (flash loan protection)
- Role-based access: Owner, Guardian, AuthorizedUpdater

## Testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/unit/LTVCalculator.t.sol

# Run with gas reporting
forge test --gas-report

# Run fuzz tests
forge test --fuzz-runs 1000

# Coverage
forge coverage
```

## License

MIT
