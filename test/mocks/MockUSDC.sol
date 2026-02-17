// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Mock USDC token for testing
 * @dev Uses 6 decimals like real USDC
 */
contract MockUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {}

    /**
     * @notice Returns the number of decimals
     * @return The number of decimals (6)
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Mint tokens to an address (for testing)
     * @param to Recipient address
     * @param amount Amount to mint (in 6 decimal units)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address (for testing)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /**
     * @notice Mint tokens with a convenient helper (1 USDC = 1e6)
     * @param to Recipient address
     * @param usdcAmount Amount in whole USDC units
     */
    function mintUSDC(address to, uint256 usdcAmount) external {
        _mint(to, usdcAmount * 10 ** DECIMALS);
    }

    /**
     * @notice Get balance in whole USDC units
     * @param account Address to check
     * @return Balance in whole USDC
     */
    function balanceInUSDC(address account) external view returns (uint256) {
        return balanceOf(account) / 10 ** DECIMALS;
    }
}
