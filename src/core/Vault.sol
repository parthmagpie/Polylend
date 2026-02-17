// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/DataTypes.sol";
import "../libraries/Errors.sol";
import "../interfaces/IVault.sol";

/**
 * @title Vault
 * @notice Holds ERC-1155 conditional tokens as collateral for the PolyLend protocol
 * @dev Manages deposits, withdrawals, and liquidation transfers of collateral
 */
contract Vault is IVault, ERC1155Holder, ReentrancyGuard, Ownable {
    // ============ Storage ============

    /// @notice The Conditional Token Framework contract address
    address public immutable override ctf;

    /// @notice The main PolyLend contract (authorized to manage collateral)
    address public polyLend;

    /// @notice The liquidation engine (authorized for seizures)
    address public liquidationEngine;

    /// @notice Collateral balances: user => tokenId => amount
    mapping(address => mapping(uint256 => uint256)) public collateralBalances;

    /// @notice Collateral info: user => tokenId => CollateralInfo
    mapping(address => mapping(uint256 => DataTypes.CollateralInfo)) public collateralInfo;

    /// @notice Total collateral per token: tokenId => total amount
    mapping(uint256 => uint256) public totalCollateralPerToken;

    // ============ Events ============

    event PolyLendSet(address indexed polyLend);
    event LiquidationEngineSet(address indexed liquidationEngine);

    // ============ Modifiers ============

    modifier onlyPolyLend() {
        if (msg.sender != polyLend) {
            revert Errors.Unauthorized();
        }
        _;
    }

    modifier onlyLiquidationEngine() {
        if (msg.sender != liquidationEngine && msg.sender != polyLend) {
            revert Errors.NotLiquidationEngine();
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the vault with the CTF address
     * @param _ctf The Conditional Token Framework contract address
     */
    constructor(address _ctf) Ownable(msg.sender) {
        if (_ctf == address(0)) {
            revert Errors.ZeroAddress();
        }
        ctf = _ctf;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the PolyLend contract address
     * @param _polyLend The PolyLend contract address
     */
    function setPolyLend(address _polyLend) external onlyOwner {
        if (_polyLend == address(0)) {
            revert Errors.ZeroAddress();
        }
        polyLend = _polyLend;
        emit PolyLendSet(_polyLend);
    }

    /**
     * @notice Set the liquidation engine address
     * @param _liquidationEngine The liquidation engine contract address
     */
    function setLiquidationEngine(address _liquidationEngine) external onlyOwner {
        if (_liquidationEngine == address(0)) {
            revert Errors.ZeroAddress();
        }
        liquidationEngine = _liquidationEngine;
        emit LiquidationEngineSet(_liquidationEngine);
    }

    // ============ Deposit Functions ============

    /**
     * @notice Deposit ERC-1155 collateral (called by users through PolyLend)
     * @param tokenId The token ID to deposit
     * @param amount The amount to deposit
     * @param marketId The associated market condition ID
     */
    function depositCollateral(
        uint256 tokenId,
        uint256 amount,
        bytes32 marketId
    ) external override nonReentrant {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        address depositor = msg.sender;

        // If called through PolyLend, the actual depositor info should be passed
        // For direct calls, msg.sender is the depositor

        // Transfer tokens from depositor to vault
        IERC1155(ctf).safeTransferFrom(depositor, address(this), tokenId, amount, "");

        // Update balances
        collateralBalances[depositor][tokenId] += amount;
        totalCollateralPerToken[tokenId] += amount;

        // Update or create collateral info
        DataTypes.CollateralInfo storage info = collateralInfo[depositor][tokenId];
        if (info.amount == 0) {
            info.owner = depositor;
            info.tokenId = tokenId;
            info.marketId = marketId;
            info.depositTimestamp = block.timestamp;
        }
        info.amount += amount;

        emit CollateralDeposited(depositor, tokenId, amount, marketId);
    }

    /**
     * @notice Deposit collateral on behalf of a user (called by PolyLend)
     * @param user The user to credit
     * @param tokenId The token ID
     * @param amount The amount
     * @param marketId The market condition ID
     */
    function depositCollateralFor(
        address user,
        uint256 tokenId,
        uint256 amount,
        bytes32 marketId
    ) external nonReentrant onlyPolyLend {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }
        if (user == address(0)) {
            revert Errors.ZeroAddress();
        }

        // Note: PolyLend should have already transferred tokens to vault
        // This function just updates accounting

        collateralBalances[user][tokenId] += amount;
        totalCollateralPerToken[tokenId] += amount;

        DataTypes.CollateralInfo storage info = collateralInfo[user][tokenId];
        if (info.amount == 0) {
            info.owner = user;
            info.tokenId = tokenId;
            info.marketId = marketId;
            info.depositTimestamp = block.timestamp;
        }
        info.amount += amount;

        emit CollateralDeposited(user, tokenId, amount, marketId);
    }

    // ============ Withdrawal Functions ============

    /**
     * @notice Withdraw ERC-1155 collateral
     * @param tokenId The token ID to withdraw
     * @param amount The amount to withdraw
     */
    function withdrawCollateral(uint256 tokenId, uint256 amount) external override nonReentrant {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        address withdrawer = msg.sender;

        if (collateralBalances[withdrawer][tokenId] < amount) {
            revert Errors.InsufficientCollateral(collateralBalances[withdrawer][tokenId], amount);
        }

        // Update balances
        collateralBalances[withdrawer][tokenId] -= amount;
        totalCollateralPerToken[tokenId] -= amount;
        collateralInfo[withdrawer][tokenId].amount -= amount;

        // Transfer tokens back to withdrawer
        IERC1155(ctf).safeTransferFrom(address(this), withdrawer, tokenId, amount, "");

        emit CollateralWithdrawn(withdrawer, tokenId, amount);
    }

    /**
     * @notice Withdraw collateral on behalf of a user (called by PolyLend after health check)
     * @param user The user to withdraw for
     * @param tokenId The token ID
     * @param amount The amount
     */
    function withdrawCollateralFor(
        address user,
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant onlyPolyLend {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }

        if (collateralBalances[user][tokenId] < amount) {
            revert Errors.InsufficientCollateral(collateralBalances[user][tokenId], amount);
        }

        collateralBalances[user][tokenId] -= amount;
        totalCollateralPerToken[tokenId] -= amount;
        collateralInfo[user][tokenId].amount -= amount;

        // Transfer tokens to user
        IERC1155(ctf).safeTransferFrom(address(this), user, tokenId, amount, "");

        emit CollateralWithdrawn(user, tokenId, amount);
    }

    // ============ Liquidation Functions ============

    /**
     * @notice Transfer collateral from borrower to liquidator during liquidation
     * @param from The borrower being liquidated
     * @param to The liquidator receiving collateral
     * @param tokenId The token ID to transfer
     * @param amount The amount to transfer
     */
    function transferCollateralToLiquidator(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external override nonReentrant onlyLiquidationEngine {
        if (amount == 0) {
            revert Errors.ZeroAmount();
        }
        if (to == address(0)) {
            revert Errors.ZeroAddress();
        }

        if (collateralBalances[from][tokenId] < amount) {
            revert Errors.InsufficientCollateral(collateralBalances[from][tokenId], amount);
        }

        // Update borrower's balance
        collateralBalances[from][tokenId] -= amount;
        collateralInfo[from][tokenId].amount -= amount;

        // Transfer tokens to liquidator
        IERC1155(ctf).safeTransferFrom(address(this), to, tokenId, amount, "");

        emit CollateralSeized(from, to, tokenId, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get collateral balance for a user and token
     * @param user The user address
     * @param tokenId The token ID
     * @return The collateral amount
     */
    function getCollateralBalance(
        address user,
        uint256 tokenId
    ) external view override returns (uint256) {
        return collateralBalances[user][tokenId];
    }

    /**
     * @notice Get full collateral info for a user and token
     * @param user The user address
     * @param tokenId The token ID
     * @return The collateral information
     */
    function getCollateralInfo(
        address user,
        uint256 tokenId
    ) external view override returns (DataTypes.CollateralInfo memory) {
        return collateralInfo[user][tokenId];
    }

    /**
     * @notice Get total collateral held in vault for a token
     * @param tokenId The token ID
     * @return The total amount held
     */
    function getTotalCollateral(uint256 tokenId) external view override returns (uint256) {
        return totalCollateralPerToken[tokenId];
    }

    /**
     * @notice Check if a user has any collateral for a token
     * @param user The user address
     * @param tokenId The token ID
     * @return True if user has collateral
     */
    function hasCollateral(address user, uint256 tokenId) external view returns (bool) {
        return collateralBalances[user][tokenId] > 0;
    }
}
