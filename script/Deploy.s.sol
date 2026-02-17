// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PolyLend.sol";
import "../src/core/Vault.sol";
import "../src/core/LendingPool.sol";
import "../src/core/LiquidationEngine.sol";
import "../src/oracle/PolymarketTWAPOracle.sol";
import "../src/risk/MarketRegistry.sol";
import "../src/risk/LTVCalculator.sol";
import "../src/risk/CircuitBreaker.sol";

/**
 * @title Deploy
 * @notice Deployment script for the PolyLend protocol
 * @dev Deploys all contracts in the correct order and configures access control
 *
 * Deployment Order:
 * 1. MarketRegistry
 * 2. LTVCalculator (→ MarketRegistry)
 * 3. PolymarketTWAPOracle
 * 4. CircuitBreaker (→ MarketRegistry)
 * 5. Vault (→ CTF address)
 * 6. LendingPool (→ USDC address)
 * 7. LiquidationEngine (→ Vault, LendingPool, Oracle)
 * 8. PolyLend (→ all above)
 * 9. Configure access control & wire contracts together
 */
contract Deploy is Script {
    // Polygon Mainnet addresses
    address constant POLYGON_CTF = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address constant POLYGON_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    // Deployed contracts
    MarketRegistry public marketRegistry;
    LTVCalculator public ltvCalculator;
    PolymarketTWAPOracle public oracle;
    CircuitBreaker public circuitBreaker;
    Vault public vault;
    LendingPool public lendingPool;
    LiquidationEngine public liquidationEngine;
    PolyLend public polyLend;

    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying PolyLend Protocol");
        console.log("Deployer:", deployer);
        console.log("Network: Polygon Mainnet");
        console.log("CTF:", POLYGON_CTF);
        console.log("USDC:", POLYGON_USDC);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MarketRegistry
        console.log("1. Deploying MarketRegistry...");
        marketRegistry = new MarketRegistry();
        console.log("   MarketRegistry:", address(marketRegistry));

        // 2. Deploy LTVCalculator
        console.log("2. Deploying LTVCalculator...");
        ltvCalculator = new LTVCalculator(address(marketRegistry));
        console.log("   LTVCalculator:", address(ltvCalculator));

        // 3. Deploy Oracle
        console.log("3. Deploying PolymarketTWAPOracle...");
        oracle = new PolymarketTWAPOracle();
        console.log("   PolymarketTWAPOracle:", address(oracle));

        // 4. Deploy CircuitBreaker
        console.log("4. Deploying CircuitBreaker...");
        circuitBreaker = new CircuitBreaker(address(marketRegistry));
        console.log("   CircuitBreaker:", address(circuitBreaker));

        // 5. Deploy Vault
        console.log("5. Deploying Vault...");
        vault = new Vault(POLYGON_CTF);
        console.log("   Vault:", address(vault));

        // 6. Deploy LendingPool
        console.log("6. Deploying LendingPool...");
        lendingPool = new LendingPool(POLYGON_USDC);
        console.log("   LendingPool:", address(lendingPool));

        // 7. Deploy LiquidationEngine
        console.log("7. Deploying LiquidationEngine...");
        liquidationEngine = new LiquidationEngine();
        console.log("   LiquidationEngine:", address(liquidationEngine));

        // 8. Deploy PolyLend
        console.log("8. Deploying PolyLend...");
        polyLend = new PolyLend();
        console.log("   PolyLend:", address(polyLend));

        console.log("");
        console.log("Configuring contracts...");

        // 9. Configure access control

        // Configure LiquidationEngine
        console.log("   Configuring LiquidationEngine...");
        liquidationEngine.setContracts(
            address(vault),
            address(lendingPool),
            address(oracle),
            POLYGON_USDC
        );
        liquidationEngine.setPolyLend(address(polyLend));

        // Configure Vault
        console.log("   Configuring Vault...");
        vault.setPolyLend(address(polyLend));
        vault.setLiquidationEngine(address(liquidationEngine));

        // Configure LendingPool
        console.log("   Configuring LendingPool...");
        lendingPool.setPolyLend(address(polyLend));

        // Initialize PolyLend
        console.log("   Initializing PolyLend...");
        polyLend.initialize(
            address(vault),
            address(lendingPool),
            address(liquidationEngine),
            address(oracle),
            address(marketRegistry),
            address(ltvCalculator),
            address(circuitBreaker),
            POLYGON_USDC,
            POLYGON_CTF
        );

        // Add deployer as guardian for emergency controls
        console.log("   Adding deployer as guardian...");
        marketRegistry.addGuardian(deployer);
        circuitBreaker.addGuardian(deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("Contract Addresses:");
        console.log("  MarketRegistry:", address(marketRegistry));
        console.log("  LTVCalculator:", address(ltvCalculator));
        console.log("  PolymarketTWAPOracle:", address(oracle));
        console.log("  CircuitBreaker:", address(circuitBreaker));
        console.log("  Vault:", address(vault));
        console.log("  LendingPool:", address(lendingPool));
        console.log("  LiquidationEngine:", address(liquidationEngine));
        console.log("  PolyLend:", address(polyLend));
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Register markets via MarketRegistry.registerMarket()");
        console.log("  2. Map token IDs to markets via MarketRegistry.mapTokenToMarket()");
        console.log("  3. Authorize oracle updaters via oracle.authorizeUpdater()");
        console.log("  4. Start recording price observations");
    }
}

/**
 * @title DeployTestnet
 * @notice Deployment script for testnet with mock tokens
 */
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying PolyLend Protocol (Testnet)");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock tokens first
        // Note: In a real testnet deployment, you would deploy MockCTF and MockUSDC here
        // For now, we'll use placeholder addresses that should be replaced

        address mockCTF = address(0); // Replace with deployed MockCTF
        address mockUSDC = address(0); // Replace with deployed MockUSDC

        require(mockCTF != address(0) && mockUSDC != address(0), "Deploy mock tokens first");

        // Deploy protocol (same as mainnet but with mock addresses)
        MarketRegistry marketRegistry = new MarketRegistry();
        LTVCalculator ltvCalculator = new LTVCalculator(address(marketRegistry));
        PolymarketTWAPOracle oracle = new PolymarketTWAPOracle();
        CircuitBreaker circuitBreaker = new CircuitBreaker(address(marketRegistry));
        Vault vault = new Vault(mockCTF);
        LendingPool lendingPool = new LendingPool(mockUSDC);
        LiquidationEngine liquidationEngine = new LiquidationEngine();
        PolyLend polyLend = new PolyLend();

        // Configure
        liquidationEngine.setContracts(
            address(vault),
            address(lendingPool),
            address(oracle),
            mockUSDC
        );
        liquidationEngine.setPolyLend(address(polyLend));
        vault.setPolyLend(address(polyLend));
        vault.setLiquidationEngine(address(liquidationEngine));
        lendingPool.setPolyLend(address(polyLend));

        polyLend.initialize(
            address(vault),
            address(lendingPool),
            address(liquidationEngine),
            address(oracle),
            address(marketRegistry),
            address(ltvCalculator),
            address(circuitBreaker),
            mockUSDC,
            mockCTF
        );

        marketRegistry.addGuardian(deployer);
        circuitBreaker.addGuardian(deployer);

        vm.stopBroadcast();

        console.log("Testnet deployment complete");
        console.log("PolyLend:", address(polyLend));
    }
}
