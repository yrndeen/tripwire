// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { TripwirePool } from "./TripwirePool.sol";

interface IERC20Vault {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TripwireVault
/// @notice Destination-chain callback contract on Unichain Sepolia (chain ID 1301).
/// @dev Users deposit token0 and register stop-loss / take-profit brackets. When the Reactive Omni
///      contract on Lasna detects a threshold crossing, the Reactive callback proxy calls executeOrder,
///      unwinding the configured exitBps through TripwirePool and recording full-loop latency metrics.
contract TripwireVault is AbstractCallback {
    uint16 public constant MAX_BPS = 10_000;
    uint8 public constant TRIGGER_STOP_LOSS = 1;
    uint8 public constant TRIGGER_TAKE_PROFIT = 2;

    enum OrderStatus {
        None,
        Active,
        Executed,
        Cancelled
    }

    struct Order {
        uint256 id;
        address owner;
        uint256 amountIn;
        uint256 stopLossPriceE18;
        uint256 takeProfitPriceE18;
        uint256 minOut;
        uint16 exitBps;
        OrderStatus status;
        uint64 createdAt;
    }

    struct ExecutionRecord {
        uint8 triggerType;
        uint256 triggerPriceE18;
        uint256 amountSwapped;
        uint256 amountOut;
        uint256 remainderReturned;
        uint64 originTimestamp;
        uint64 reactiveTimestamp;
        uint64 callbackTimestamp;
        uint64 originToReactiveSec;
        uint64 fullLoopSec;
    }

    TripwirePool public immutable pool;
    IERC20Vault public immutable token0;
    IERC20Vault public immutable token1;

    uint256 public nextOrderId = 1;
    uint256 public executedCount;
    uint256 public cumulativeFullLoopSec;

    mapping(uint256 => Order) public orders;
    mapping(uint256 => ExecutionRecord) public executions;

    uint256 private _locked = 1;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amountIn,
        uint256 stopLossPriceE18,
        uint256 takeProfitPriceE18,
        uint16 exitBps
    );

    event OrderCancelled(uint256 indexed orderId, address indexed owner, uint256 refundedAmount);

    event OrderExecuted(
        uint256 indexed orderId,
        address indexed owner,
        uint8 triggerType,
        uint256 amountSwapped,
        uint256 amountOut,
        uint256 remainderReturned,
        uint64 originTimestamp,
        uint64 reactiveTimestamp,
        uint64 callbackTimestamp,
        uint64 fullLoopSec
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidThresholds();
    error InvalidExitBps();
    error NotOrderOwner();
    error OrderNotActive();
    error InvalidTriggerType();
    error ThresholdNotMet(uint256 spotPriceE18);
    error TokenTransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        address pool_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        if (address(callbackProxy_) == address(0) || callbackSender_ == address(0) || pool_ == address(0)) {
            revert ZeroAddress();
        }
        pool = TripwirePool(pool_);
        token0 = IERC20Vault(address(pool.token0()));
        token1 = IERC20Vault(address(pool.token1()));
    }

    /// @notice Deposits token0 and creates an automated stop-loss / take-profit order.
    /// @param amountIn Amount of token0 to lock in the vault.
    /// @param stopLossPriceE18 Trigger stop-loss when spotPriceE18 <= stopLossPriceE18 (0 disables SL).
    /// @param takeProfitPriceE18 Trigger take-profit when spotPriceE18 >= takeProfitPriceE18 (0 disables TP).
    /// @param minOut Minimum token1 received from the pool swap on exit.
    /// @param exitBps Portion of amountIn to swap on trigger (1..10000); remainder is returned to owner.
    function createOrder(
        uint256 amountIn,
        uint256 stopLossPriceE18,
        uint256 takeProfitPriceE18,
        uint256 minOut,
        uint16 exitBps
    ) external nonReentrant returns (uint256 orderId) {
        if (amountIn == 0) revert ZeroAmount();
        if (stopLossPriceE18 == 0 && takeProfitPriceE18 == 0) revert InvalidThresholds();
        if (stopLossPriceE18 != 0 && takeProfitPriceE18 != 0 && stopLossPriceE18 >= takeProfitPriceE18) {
            revert InvalidThresholds();
        }
        if (exitBps == 0 || exitBps > MAX_BPS) revert InvalidExitBps();

        orderId = nextOrderId++;
        orders[orderId] = Order({
            id: orderId,
            owner: msg.sender,
            amountIn: amountIn,
            stopLossPriceE18: stopLossPriceE18,
            takeProfitPriceE18: takeProfitPriceE18,
            minOut: minOut,
            exitBps: exitBps,
            status: OrderStatus.Active,
            createdAt: uint64(block.timestamp)
        });

        if (!token0.transferFrom(msg.sender, address(this), amountIn)) revert TokenTransferFailed();

        emit OrderCreated(
            orderId,
            msg.sender,
            amountIn,
            stopLossPriceE18,
            takeProfitPriceE18,
            exitBps
        );
    }

    /// @notice Cancels an active order and refunds the full token0 deposit to the order owner.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.status != OrderStatus.Active) revert OrderNotActive();
        if (order.owner != msg.sender) revert NotOrderOwner();

        uint256 refund = order.amountIn;
        order.status = OrderStatus.Cancelled;

        if (!token0.transfer(order.owner, refund)) revert TokenTransferFailed();

        emit OrderCancelled(orderId, order.owner, refund);
    }

    /// @notice Reactive Omni callback entry point. Guarded by both callback proxy and authorized reactive contract.
    /// @param reactive_ Injected by the callback proxy as the first 160-bit argument.
    function executeOrder(
        address reactive_,
        uint256 orderId,
        uint8 triggerType,
        uint256 triggerPriceE18,
        uint64 originTimestamp,
        uint64 reactiveTimestamp
    ) external onlyServiceProvider onlyCallbackSender(reactive_) nonReentrant {
        Order storage order = orders[orderId];
        if (order.status != OrderStatus.Active) revert OrderNotActive();

        uint256 spot = pool.spotPriceE18();
        if (triggerType == TRIGGER_STOP_LOSS) {
            if (order.stopLossPriceE18 == 0 || spot > order.stopLossPriceE18) {
                revert ThresholdNotMet(spot);
            }
        } else if (triggerType == TRIGGER_TAKE_PROFIT) {
            if (order.takeProfitPriceE18 == 0 || spot < order.takeProfitPriceE18) {
                revert ThresholdNotMet(spot);
            }
        } else {
            revert InvalidTriggerType();
        }

        uint256 amountToSwap = (order.amountIn * uint256(order.exitBps)) / uint256(MAX_BPS);
        if (amountToSwap == 0) revert ZeroAmount();
        uint256 remainder = order.amountIn - amountToSwap;

        // Effects before interactions (prevents double-fire and reentrancy)
        order.status = OrderStatus.Executed;

        uint64 callbackTs = uint64(block.timestamp);
        uint64 originToReactive = reactiveTimestamp >= originTimestamp
            ? reactiveTimestamp - originTimestamp
            : 0;
        uint64 fullLoop = callbackTs >= originTimestamp
            ? callbackTs - originTimestamp
            : 0;

        if (!token0.approve(address(pool), amountToSwap)) revert TokenTransferFailed();
        uint256 amountOut = pool.swapExactIn(true, amountToSwap, order.minOut, order.owner);

        if (remainder > 0) {
            if (!token0.transfer(order.owner, remainder)) revert TokenTransferFailed();
        }

        executions[orderId] = ExecutionRecord({
            triggerType: triggerType,
            triggerPriceE18: triggerPriceE18,
            amountSwapped: amountToSwap,
            amountOut: amountOut,
            remainderReturned: remainder,
            originTimestamp: originTimestamp,
            reactiveTimestamp: reactiveTimestamp,
            callbackTimestamp: callbackTs,
            originToReactiveSec: originToReactive,
            fullLoopSec: fullLoop
        });

        executedCount += 1;
        cumulativeFullLoopSec += fullLoop;

        emit OrderExecuted(
            orderId,
            order.owner,
            triggerType,
            amountToSwap,
            amountOut,
            remainder,
            originTimestamp,
            reactiveTimestamp,
            callbackTs,
            fullLoop
        );
    }

    /// @notice Returns the average full-loop execution latency in seconds across executed orders.
    function averageFullLoopSec() external view returns (uint256) {
        if (executedCount == 0) return 0;
        return cumulativeFullLoopSec / executedCount;
    }

    /// @notice Settles any outstanding callback proxy debt from this contract's native balance.
    function coverDebt() external {
        _coverDebt();
    }
}
