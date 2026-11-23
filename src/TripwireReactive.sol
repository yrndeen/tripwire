// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title TripwireReactive
/// @notice Reactive Omni contract deployed on Reactive Lasna testnet (chain ID 5318007).
/// @dev Subscribes to TripwireVault order lifecycle events and TripwirePool PriceUpdated events
///      on Unichain Sepolia (1301). Tracks active SL/TP brackets in Lasna state and autonomously
///      dispatches SYSTEM.requestCallbackV_1_0 callbacks on threshold crossings.
contract TripwireReactive is AbstractReactive {
    uint8 public constant TRIGGER_STOP_LOSS = 1;
    uint8 public constant TRIGGER_TAKE_PROFIT = 2;

    uint256 public constant ORDER_CREATED_TOPIC0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256,uint256,uint16)"));
    uint256 public constant ORDER_CANCELLED_TOPIC0 =
        uint256(keccak256("OrderCancelled(uint256,address,uint256)"));
    uint256 public constant PRICE_UPDATED_TOPIC0 =
        uint256(keccak256("PriceUpdated(uint256,uint256,uint256,uint64)"));

    struct TrackedOrder {
        uint256 stopLossPriceE18;
        uint256 takeProfitPriceE18;
        bool active;
        bool triggered;
    }

    address public immutable owner;
    uint256 public immutable originChainId;
    uint256 public immutable destinationChainId;
    uint64 public callbackGasLimit;

    address public pool;
    address public vault;
    bool public configured;
    bool public paused;

    uint256[] private _activeOrderIds;
    mapping(uint256 => uint256) private _activeIndexPlusOne;
    mapping(uint256 => TrackedOrder) public trackedOrders;

    uint256 public eventsProcessed;
    uint256 public callbacksRequested;
    uint256 public lastObservedPriceE18;
    uint64 public lastOriginTimestamp;
    uint64 public lastReactiveTimestamp;

    event Configured(address indexed pool, address indexed vault);
    event OrderTracked(uint256 indexed orderId, uint256 stopLossPriceE18, uint256 takeProfitPriceE18);
    event OrderUntracked(uint256 indexed orderId);
    event TripwireFired(
        uint256 indexed orderId,
        uint8 triggerType,
        uint256 priceE18,
        uint64 originTimestamp,
        uint64 reactiveTimestamp
    );
    event PausedChanged(bool paused);

    error NotOwner();
    error ZeroAddress();
    error AlreadyConfigured();
    error NotConfigured();
    error InvalidGasLimit();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 originChainId_,
        uint256 destinationChainId_,
        uint64 callbackGasLimit_
    ) payable AbstractReactive() {
        if (callbackGasLimit_ < 100_000) revert InvalidGasLimit();
        owner = msg.sender;
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
        callbackGasLimit = callbackGasLimit_;
    }

    /// @notice Links the Unichain Sepolia pool and vault and activates all three Omni subscriptions.
    function configure(address pool_, address vault_) external onlyOwner {
        if (configured) revert AlreadyConfigured();
        if (pool_ == address(0) || vault_ == address(0)) revert ZeroAddress();

        pool = pool_;
        vault = vault_;
        configured = true;

        SYSTEM.subscribe(
            originChainId,
            vault_,
            ORDER_CREATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            originChainId,
            vault_,
            ORDER_CANCELLED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            originChainId,
            pool_,
            PRICE_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        emit Configured(pool_, vault_);
    }

    /// @notice Pauses or resumes reactive callback dispatching without dropping subscriptions.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedChanged(paused_);
    }

    /// @notice Updates the callback gas limit for future callback requests.
    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        if (gasLimit_ < 100_000) revert InvalidGasLimit();
        callbackGasLimit = gasLimit_;
    }

    /// @notice Unsubscribes from all origin events (owner cleanup).
    function unsubscribeAll() external onlyOwner {
        if (!configured) revert NotConfigured();
        SYSTEM.unsubscribe(
            originChainId,
            vault,
            ORDER_CREATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            originChainId,
            vault,
            ORDER_CANCELLED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.unsubscribe(
            originChainId,
            pool,
            PRICE_UPDATED_TOPIC0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        if (!configured || log_.chainId != originChainId) return;

        eventsProcessed += 1;

        if (log_.contractAddress == vault && log_.topic0 == ORDER_CREATED_TOPIC0) {
            _handleOrderCreated(log_);
        } else if (log_.contractAddress == vault && log_.topic0 == ORDER_CANCELLED_TOPIC0) {
            _handleOrderCancelled(log_);
        } else if (log_.contractAddress == pool && log_.topic0 == PRICE_UPDATED_TOPIC0) {
            _handlePriceUpdated(log_);
        }
    }

    function _handleOrderCreated(LogRecord calldata log_) internal {
        uint256 orderId = log_.topic1;
        (, uint256 stopLossPriceE18, uint256 takeProfitPriceE18, ) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint16));

        TrackedOrder storage t = trackedOrders[orderId];
        if (t.active || t.triggered) return;

        t.stopLossPriceE18 = stopLossPriceE18;
        t.takeProfitPriceE18 = takeProfitPriceE18;
        t.active = true;

        _activeOrderIds.push(orderId);
        _activeIndexPlusOne[orderId] = _activeOrderIds.length;

        emit OrderTracked(orderId, stopLossPriceE18, takeProfitPriceE18);
    }

    function _handleOrderCancelled(LogRecord calldata log_) internal {
        uint256 orderId = log_.topic1;
        TrackedOrder storage t = trackedOrders[orderId];
        if (!t.active) return;

        t.active = false;
        _removeActiveOrder(orderId);

        emit OrderUntracked(orderId);
    }

    function _handlePriceUpdated(LogRecord calldata log_) internal {
        (uint256 priceE18, , , uint64 originTs) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint64));

        uint64 reactiveTs = uint64(block.timestamp);
        lastObservedPriceE18 = priceE18;
        lastOriginTimestamp = originTs;
        lastReactiveTimestamp = reactiveTs;

        if (paused) return;

        uint256 i = 0;
        while (i < _activeOrderIds.length) {
            uint256 orderId = _activeOrderIds[i];
            TrackedOrder storage t = trackedOrders[orderId];

            uint8 triggerType = 0;
            if (t.stopLossPriceE18 != 0 && priceE18 <= t.stopLossPriceE18) {
                triggerType = TRIGGER_STOP_LOSS;
            } else if (t.takeProfitPriceE18 != 0 && priceE18 >= t.takeProfitPriceE18) {
                triggerType = TRIGGER_TAKE_PROFIT;
            }

            if (triggerType != 0) {
                t.active = false;
                t.triggered = true;
                _removeActiveOrder(orderId);

                bytes memory payload = abi.encodeWithSignature(
                    "executeOrder(address,uint256,uint8,uint256,uint64,uint64)",
                    address(0),
                    orderId,
                    triggerType,
                    priceE18,
                    originTs,
                    reactiveTs
                );

                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: destinationChainId,
                        recipient: vault,
                        gasLimit: callbackGasLimit,
                        payload: payload
                    })
                );

                callbacksRequested += 1;
                emit TripwireFired(orderId, triggerType, priceE18, originTs, reactiveTs);
                // Do not increment i; swap-and-pop moved a new element into index i.
            } else {
                i += 1;
            }
        }
    }

    function _removeActiveOrder(uint256 orderId) internal {
        uint256 idxPlusOne = _activeIndexPlusOne[orderId];
        if (idxPlusOne == 0) return;

        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = _activeOrderIds.length - 1;
        if (idx != lastIdx) {
            uint256 movedId = _activeOrderIds[lastIdx];
            _activeOrderIds[idx] = movedId;
            _activeIndexPlusOne[movedId] = idx + 1;
        }
        _activeOrderIds.pop();
        delete _activeIndexPlusOne[orderId];
    }

    function activeOrderCount() external view returns (uint256) {
        return _activeOrderIds.length;
    }

    function getActiveOrderIds() external view returns (uint256[] memory) {
        return _activeOrderIds;
    }

    /// @notice Settles any outstanding reactive network debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
