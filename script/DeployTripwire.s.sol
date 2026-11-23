// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { MockERC20 } from "../src/MockERC20.sol";
import { TripwirePool } from "../src/TripwirePool.sol";
import { TripwireVault } from "../src/TripwireVault.sol";
import { TripwireReactive } from "../src/TripwireReactive.sol";

/// @notice Step 1: Deploy TripwireReactive on Reactive Lasna Testnet (chain ID 5318007).
/// @dev Strictly refuses to run on mainnet; requires throwaway testnet PRIVATE_KEY in env.
contract DeployReactiveLasna is Script {
    uint256 internal constant LASNA_CHAIN_ID = 5318007;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint64 internal constant DEFAULT_CALLBACK_GAS_LIMIT = 500_000;

    function run() external {
        require(block.chainid == LASNA_CHAIN_ID, "ABORT: must run on Reactive Lasna (5318007)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 fundAmount = vm.envOr("REACTIVE_FUND_WEI", uint256(0.05 ether));

        vm.startBroadcast(pk);
        TripwireReactive reactive = new TripwireReactive{ value: fundAmount }(
            UNICHAIN_SEPOLIA_CHAIN_ID,
            UNICHAIN_SEPOLIA_CHAIN_ID,
            DEFAULT_CALLBACK_GAS_LIMIT
        );
        vm.stopBroadcast();

        console2.log("TripwireReactive (Lasna 5318007):", address(reactive));
    }
}

/// @notice Step 2: Deploy MockERC20 pair, TripwirePool, and TripwireVault on Unichain Sepolia (1301).
contract DeployUnichainOriginDest is Script {
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY =
        0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function run() external {
        require(
            block.chainid == UNICHAIN_SEPOLIA_CHAIN_ID,
            "ABORT: must run on Unichain Sepolia (1301)"
        );
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address reactiveSender = vm.envAddress("REACTIVE_CONTRACT");
        uint256 vaultFund = vm.envOr("VAULT_FUND_WEI", uint256(0.02 ether));

        vm.startBroadcast(pk);
        MockERC20 tWeth = new MockERC20("Tripwire Test WETH", "tWETH", 18);
        MockERC20 tUsdc = new MockERC20("Tripwire Test USDC", "tUSDC", 18);
        TripwirePool pool = new TripwirePool(address(tWeth), address(tUsdc));

        // Seed 100 tWETH / 200,000 tUSDC (2,000 tUSDC per tWETH)
        address deployer = vm.addr(pk);
        tWeth.mint(deployer, 200 ether);
        tUsdc.mint(deployer, 400_000 ether);
        tWeth.approve(address(pool), type(uint256).max);
        tUsdc.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100 ether, 200_000 ether);

        TripwireVault vault = new TripwireVault{ value: vaultFund }(
            IPayable(payable(UNICHAIN_SEPOLIA_CALLBACK_PROXY)),
            reactiveSender,
            address(pool)
        );
        vm.stopBroadcast();

        console2.log("tWETH:", address(tWeth));
        console2.log("tUSDC:", address(tUsdc));
        console2.log("TripwirePool (Unichain Sepolia 1301):", address(pool));
        console2.log("TripwireVault (Unichain Sepolia 1301):", address(vault));
    }
}

/// @notice Step 3: Configure TripwireReactive on Lasna (5318007) to subscribe to pool + vault.
contract ConfigureReactiveLasna is Script {
    uint256 internal constant LASNA_CHAIN_ID = 5318007;

    function run() external {
        require(block.chainid == LASNA_CHAIN_ID, "ABORT: must run on Reactive Lasna (5318007)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address reactiveAddr = vm.envAddress("REACTIVE_CONTRACT");
        address poolAddr = vm.envAddress("POOL_CONTRACT");
        address vaultAddr = vm.envAddress("VAULT_CONTRACT");

        vm.startBroadcast(pk);
        TripwireReactive(payable(reactiveAddr)).configure(poolAddr, vaultAddr);
        vm.stopBroadcast();

        console2.log("Configured TripwireReactive:", reactiveAddr);
        console2.log("  Subscribed pool:", poolAddr);
        console2.log("  Subscribed vault:", vaultAddr);
    }
}
