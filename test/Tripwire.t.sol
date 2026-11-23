// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { MockERC20 } from "../src/MockERC20.sol";
import { TripwirePool } from "../src/TripwirePool.sol";
import { TripwireVault } from "../src/TripwireVault.sol";
import { TripwireReactive } from "../src/TripwireReactive.sol";

/// @notice Local mock of Reactive Omni SystemContract etched at 0x8888...8888 for deterministic Foundry tests.
contract MockSystemContract is ISystemContract {
    struct Sub {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
    }

    struct PendingCallback {
        address caller;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] public subscriptions;
    PendingCallback[] public pendingCallbacks;
    uint256 public unsubscribeCount;

    receive() external payable {}

    function debt(address) external pure override returns (uint256) {
        return 0;
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256,
        uint256,
        uint256
    ) external override {
        subscriptions.push(Sub(msg.sender, chainId_, contract_, topic0_));
    }

    function unsubscribe(
        uint256,
        address,
        uint256,
        uint256,
        uint256,
        uint256
    ) external override {
        unsubscribeCount += 1;
    }

    function requestCallback(CallbackVersion, bytes memory) external pure override {
        revert("use requestCallbackV_1_0");
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        pendingCallbacks.push(
            PendingCallback({
                caller: msg.sender,
                chainId: config_.chainId,
                recipient: config_.recipient,
                gasLimit: config_.gasLimit,
                payload: config_.payload
            })
        );
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return pendingCallbacks.length;
    }

    function getCallback(uint256 idx) external view returns (PendingCallback memory) {
        return pendingCallbacks[idx];
    }

    function dispatchLog(address reactiveTarget, IReactive.LogRecord memory log_) external {
        IReactive(payable(reactiveTarget)).react(log_);
    }
}

/// @notice Local mock of the Unichain Sepolia Callback Proxy.
/// @dev Overwrites the first ABI-encoded address parameter (bytes 4..36) with the requesting reactive contract,
///      matching Reactive Network's production callback proxy behavior.
contract MockCallbackProxy is IPayable {
    receive() external payable {}

    function debt(address) external pure override returns (uint256) {
        return 0;
    }

    function deliver(address reactiveSender, address recipient, bytes memory payload) external {
        bytes memory patched = new bytes(payload.length);
        for (uint256 i = 0; i < payload.length; i++) {
            patched[i] = payload[i];
        }
        // Overwrite first argument (offset 4..36) with reactiveSender
        bytes32 encodedSender = bytes32(uint256(uint160(reactiveSender)));
        assembly {
            mstore(add(patched, 36), encodedSender)
        }
        (bool ok, bytes memory ret) = recipient.call(patched);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract TripwireTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;

    MockSystemContract internal system;
    MockCallbackProxy internal proxy;
    MockERC20 internal token0; // tWETH (18 decimals)
    MockERC20 internal token1; // tUSDC (18 decimals for clean 1e18 spot prices)
    TripwirePool internal pool;
    TripwireReactive internal reactive;
    TripwireVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    function setUp() public {
        vm.warp(1_764_000_000);

        // Etch MockSystemContract at the exact Reactive Omni SYSTEM address
        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        system = MockSystemContract(payable(SYSTEM_ADDR));

        proxy = new MockCallbackProxy();

        // Deploy tokens and pool on Unichain Sepolia side
        token0 = new MockERC20("Test WETH", "tWETH", 18);
        token1 = new MockERC20("Test USDC", "tUSDC", 18);
        pool = new TripwirePool(address(token0), address(token1));

        // Seed pool at 1 tWETH = 2,000 tUSDC (100 tWETH / 200,000 tUSDC)
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 200_000 ether);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100 ether, 200_000 ether);
        assertEq(pool.spotPriceE18(), 2_000 ether);

        // Official deployment order:
        // 1. Deploy Reactive contract on Lasna
        reactive = new TripwireReactive{ value: 1 ether }(
            UNICHAIN_SEPOLIA,
            UNICHAIN_SEPOLIA,
            CALLBACK_GAS_LIMIT
        );

        // 2. Deploy Callback Vault on Unichain Sepolia pointing to proxy + reactive
        vault = new TripwireVault{ value: 1 ether }(
            IPayable(payable(address(proxy))),
            address(reactive),
            address(pool)
        );

        // 3. Configure Reactive contract to subscribe to pool + vault
        reactive.configure(address(pool), address(vault));
        assertEq(system.subscriptionCount(), 3);

        // Mint test balances to users
        token0.mint(alice, 10 ether);
        token0.mint(bob, 10 ether);
        token0.mint(trader, 50 ether);
        token1.mint(trader, 100_000 ether);

        vm.prank(alice);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(vault), type(uint256).max);
        vm.startPrank(trader);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _relayOrderCreated(
        uint256 orderId,
        address owner_,
        uint256 amountIn,
        uint256 sl,
        uint256 tp,
        uint16 exitBps
    ) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: UNICHAIN_SEPOLIA,
            contractAddress: address(vault),
            topic0: reactive.ORDER_CREATED_TOPIC0(),
            topic1: orderId,
            topic2: uint256(uint160(owner_)),
            topic3: 0,
            data: abi.encode(amountIn, sl, tp, exitBps),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 1,
            logIndex: 0
        });
        system.dispatchLog(address(reactive), log_);
    }

    function _relayOrderCancelled(uint256 orderId, address owner_, uint256 refunded) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: UNICHAIN_SEPOLIA,
            contractAddress: address(vault),
            topic0: reactive.ORDER_CANCELLED_TOPIC0(),
            topic1: orderId,
            topic2: uint256(uint160(owner_)),
            topic3: 0,
            data: abi.encode(refunded),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 2,
            logIndex: 0
        });
        system.dispatchLog(address(reactive), log_);
    }

    function _relayPriceUpdated(uint64 originTs) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: UNICHAIN_SEPOLIA,
            contractAddress: address(pool),
            topic0: reactive.PRICE_UPDATED_TOPIC0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(pool.spotPriceE18(), uint256(pool.reserve0()), uint256(pool.reserve1()), originTs),
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 3,
            logIndex: 0
        });
        system.dispatchLog(address(reactive), log_);
    }

    function test_StopLossFullLoopAndLatency() public {
        // Alice opens a 2 tWETH order: SL @ 1,800 tUSDC, TP @ 2,400 tUSDC, 100% exit
        vm.prank(alice);
        uint256 orderId = vault.createOrder(2 ether, 1_800 ether, 2_400 ether, 3_000 ether, 10_000);
        _relayOrderCreated(orderId, alice, 2 ether, 1_800 ether, 2_400 ether, 10_000);
        assertEq(reactive.activeOrderCount(), 1);

        // Trader dumps 10 tWETH into the pool, pushing price below 1,800 tUSDC
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 10 ether, 1, trader);
        uint256 crashedPrice = pool.spotPriceE18();
        assertLt(crashedPrice, 1_800 ether);

        // Simulate 1-second Reactive Omni Lasna block time
        vm.warp(originTs + 1);
        _relayPriceUpdated(originTs);

        assertEq(reactive.callbacksRequested(), 1);
        assertEq(reactive.activeOrderCount(), 0);
        assertEq(system.callbackCount(), 1);

        // Simulate 1-second Unichain Sepolia callback landing (2s total loop)
        vm.warp(originTs + 2);
        MockSystemContract.PendingCallback memory cb = system.getCallback(0);
        assertEq(cb.chainId, UNICHAIN_SEPOLIA);
        assertEq(cb.recipient, address(vault));
        assertEq(cb.caller, address(reactive));

        uint256 aliceUsdcBefore = token1.balanceOf(alice);
        proxy.deliver(cb.caller, cb.recipient, cb.payload);

        uint256 aliceUsdcAfter = token1.balanceOf(alice);
        assertGt(aliceUsdcAfter - aliceUsdcBefore, 3_000 ether);

        (, , , , , , , TripwireVault.OrderStatus status, ) = vault.orders(orderId);
        assertEq(uint8(status), uint8(TripwireVault.OrderStatus.Executed));

        (
            uint8 triggerType,
            ,
            uint256 swapped,
            uint256 amountOut,
            uint256 remainder,
            uint64 recOriginTs,
            uint64 recReactiveTs,
            uint64 recCallbackTs,
            uint64 originToReactive,
            uint64 fullLoop
        ) = vault.executions(orderId);

        assertEq(triggerType, vault.TRIGGER_STOP_LOSS());
        assertEq(swapped, 2 ether);
        assertEq(amountOut, aliceUsdcAfter - aliceUsdcBefore);
        assertEq(remainder, 0);
        assertEq(recOriginTs, originTs);
        assertEq(recReactiveTs, originTs + 1);
        assertEq(recCallbackTs, originTs + 2);
        assertEq(originToReactive, 1);
        assertEq(fullLoop, 2);
        assertEq(vault.averageFullLoopSec(), 2);
    }

    function test_TakeProfitPartialExitLoop() public {
        // Bob opens 4 tWETH order: SL @ 1,700, TP @ 2,200, 50% partial exit (5000 bps)
        vm.prank(bob);
        uint256 orderId = vault.createOrder(4 ether, 1_700 ether, 2_200 ether, 4_000 ether, 5_000);
        _relayOrderCreated(orderId, bob, 4 ether, 1_700 ether, 2_200 ether, 5_000);

        // Trader buys tWETH with 30,000 tUSDC, pushing price above 2,200 tUSDC
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(false, 30_000 ether, 1, trader);
        assertGt(pool.spotPriceE18(), 2_200 ether);

        vm.warp(originTs + 1);
        _relayPriceUpdated(originTs);
        assertEq(system.callbackCount(), 1);

        vm.warp(originTs + 2);
        MockSystemContract.PendingCallback memory cb = system.getCallback(0);
        uint256 bobWethBefore = token0.balanceOf(bob);
        uint256 bobUsdcBefore = token1.balanceOf(bob);
        proxy.deliver(cb.caller, cb.recipient, cb.payload);

        // 50% swapped to tUSDC, 50% (2 tWETH) returned to Bob
        assertEq(token0.balanceOf(bob) - bobWethBefore, 2 ether);
        assertGt(token1.balanceOf(bob) - bobUsdcBefore, 4_000 ether);

        (uint8 triggerType, , uint256 swapped, , uint256 remainder, , , , , ) = vault.executions(orderId);
        assertEq(triggerType, vault.TRIGGER_TAKE_PROFIT());
        assertEq(swapped, 2 ether);
        assertEq(remainder, 2 ether);
    }

    function test_InRangeNoOp() public {
        vm.prank(alice);
        uint256 orderId = vault.createOrder(1 ether, 1_800 ether, 2_200 ether, 1_500 ether, 10_000);
        _relayOrderCreated(orderId, alice, 1 ether, 1_800 ether, 2_200 ether, 10_000);

        // Small swap keeps price inside (1,800 .. 2,200)
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 1 ether, 1, trader);
        uint256 spot = pool.spotPriceE18();
        assertGt(spot, 1_800 ether);
        assertLt(spot, 2_200 ether);

        _relayPriceUpdated(originTs);
        assertEq(system.callbackCount(), 0);
        assertEq(reactive.activeOrderCount(), 1);
    }

    function test_CancelOrderPreventsCallback() public {
        vm.prank(alice);
        uint256 orderId = vault.createOrder(2 ether, 1_800 ether, 0, 1, 10_000);
        _relayOrderCreated(orderId, alice, 2 ether, 1_800 ether, 0, 10_000);

        uint256 balBefore = token0.balanceOf(alice);
        vm.prank(alice);
        vault.cancelOrder(orderId);
        assertEq(token0.balanceOf(alice) - balBefore, 2 ether);

        _relayOrderCancelled(orderId, alice, 2 ether);
        assertEq(reactive.activeOrderCount(), 0);

        // Even after a big dump, no callback is dispatched
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 15 ether, 1, trader);
        _relayPriceUpdated(originTs);
        assertEq(system.callbackCount(), 0);
    }

    function test_NoDoubleFireOnRepeatedPriceEventsOrReplay() public {
        vm.prank(alice);
        uint256 orderId = vault.createOrder(2 ether, 1_800 ether, 0, 1, 10_000);
        _relayOrderCreated(orderId, alice, 2 ether, 1_800 ether, 0, 10_000);

        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 10 ether, 1, trader);
        _relayPriceUpdated(originTs);
        assertEq(system.callbackCount(), 1);

        // Second price drop should NOT fire a second callback for the same order
        vm.prank(trader);
        pool.swapExactIn(true, 5 ether, 1, trader);
        _relayPriceUpdated(originTs + 1);
        assertEq(system.callbackCount(), 1);

        // First callback succeeds
        MockSystemContract.PendingCallback memory cb = system.getCallback(0);
        proxy.deliver(cb.caller, cb.recipient, cb.payload);

        // Replaying the same callback reverts with OrderNotActive
        vm.expectRevert(TripwireVault.OrderNotActive.selector);
        proxy.deliver(cb.caller, cb.recipient, cb.payload);
    }

    function test_AuthGuardsRejectSpoofedCalls() public {
        vm.prank(alice);
        uint256 orderId = vault.createOrder(1 ether, 1_800 ether, 0, 1, 10_000);

        // 1. Direct react() from non-SYSTEM reverts NotAuthorized
        IReactive.LogRecord memory dummyLog;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, SYSTEM_ADDR)
        );
        reactive.react(dummyLog);

        // 2. Direct executeOrder() bypassing callback proxy reverts NotAuthorized
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, address(proxy))
        );
        vault.executeOrder(address(reactive), orderId, 1, 1_700 ether, 1, 2);

        // 3. Callback via proxy with wrong reactive sender reverts CallbackNotAuthorized
        bytes memory spoofedPayload = abi.encodeWithSignature(
            "executeOrder(address,uint256,uint8,uint256,uint64,uint64)",
            address(0),
            orderId,
            uint8(1),
            uint256(1_700 ether),
            uint64(1),
            uint64(2)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector,
                bob,
                address(reactive)
            )
        );
        proxy.deliver(bob, address(vault), spoofedPayload);

        // 4. Non-owner cannot cancel Alice's order
        vm.prank(bob);
        vm.expectRevert(TripwireVault.NotOrderOwner.selector);
        vault.cancelOrder(orderId);

        // 5. Non-owner cannot pause reactive contract
        vm.prank(bob);
        vm.expectRevert(TripwireReactive.NotOwner.selector);
        reactive.setPaused(true);
    }

    function test_SlippageProtectionAndValidationGuards() public {
        // Validation guards
        vm.startPrank(alice);
        vm.expectRevert(TripwireVault.ZeroAmount.selector);
        vault.createOrder(0, 1_800 ether, 0, 1, 10_000);

        vm.expectRevert(TripwireVault.InvalidThresholds.selector);
        vault.createOrder(1 ether, 0, 0, 1, 10_000);

        vm.expectRevert(TripwireVault.InvalidThresholds.selector);
        vault.createOrder(1 ether, 2_200 ether, 1_800 ether, 1, 10_000);

        vm.expectRevert(TripwireVault.InvalidExitBps.selector);
        vault.createOrder(1 ether, 1_800 ether, 0, 1, 0);

        vm.expectRevert(TripwireVault.InvalidExitBps.selector);
        vault.createOrder(1 ether, 1_800 ether, 0, 1, 10_001);

        // Impossible minOut should revert inside pool swap and leave order Active
        uint256 orderId = vault.createOrder(1 ether, 1_800 ether, 0, 999_999 ether, 10_000);
        vm.stopPrank();

        _relayOrderCreated(orderId, alice, 1 ether, 1_800 ether, 0, 10_000);
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 10 ether, 1, trader);
        _relayPriceUpdated(originTs);

        MockSystemContract.PendingCallback memory cb = system.getCallback(0);
        vm.expectRevert(TripwirePool.SlippageExceeded.selector);
        proxy.deliver(cb.caller, cb.recipient, cb.payload);

        // Alice can still cancel and recover her funds cleanly
        vm.prank(alice);
        vault.cancelOrder(orderId);
        (, , , , , , , TripwireVault.OrderStatus status, ) = vault.orders(orderId);
        assertEq(uint8(status), uint8(TripwireVault.OrderStatus.Cancelled));
    }

    function test_PauseAndUnsubscribeLifecycle() public {
        vm.prank(alice);
        uint256 orderId = vault.createOrder(1 ether, 1_800 ether, 0, 1, 10_000);
        _relayOrderCreated(orderId, alice, 1 ether, 1_800 ether, 0, 10_000);

        reactive.setPaused(true);
        uint64 originTs = uint64(block.timestamp);
        vm.prank(trader);
        pool.swapExactIn(true, 10 ether, 1, trader);
        _relayPriceUpdated(originTs);
        assertEq(system.callbackCount(), 0);

        reactive.setPaused(false);
        _relayPriceUpdated(originTs + 1);
        assertEq(system.callbackCount(), 1);

        reactive.unsubscribeAll();
        assertEq(system.unsubscribeCount(), 3);
    }
}
