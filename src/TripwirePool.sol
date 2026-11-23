// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TripwirePool
/// @notice Self-contained Uniswap-v2-style constant-product AMM pair (0.30% fee) for Unichain Sepolia.
/// @dev Emits both standard Sync and a timestamped PriceUpdated event so Reactive Omni contracts
///      can evaluate stop-loss / take-profit thresholds and measure sub-second full-loop latency.
contract TripwirePool {
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;
    uint256 public constant PRICE_PRECISION = 1e18;

    IERC20Minimal public immutable token0;
    IERC20Minimal public immutable token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint64 public lastUpdateTimestamp;

    uint256 private _locked = 1;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event PriceUpdated(
        uint256 priceE18,
        uint256 reserve0,
        uint256 reserve1,
        uint64 originTimestamp
    );

    error ZeroAddress();
    error IdenticalTokens();
    error ZeroAmount();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error ReserveOverflow();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address token0_, address token1_) {
        if (token0_ == address(0) || token1_ == address(0)) revert ZeroAddress();
        if (token0_ == token1_) revert IdenticalTokens();
        token0 = IERC20Minimal(token0_);
        token1 = IERC20Minimal(token1_);
    }

    /// @notice Returns the spot price of token0 denominated in token1, scaled by 1e18.
    function spotPriceE18() public view returns (uint256) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return (uint256(reserve1) * PRICE_PRECISION) / uint256(reserve0);
    }

    /// @notice Quotes the output amount for an exact-input swap (0.30% fee).
    function getAmountOut(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        if (amountIn == 0) return 0;
        uint256 resIn = zeroForOne ? uint256(reserve0) : uint256(reserve1);
        uint256 resOut = zeroForOne ? uint256(reserve1) : uint256(reserve0);
        if (resIn == 0 || resOut == 0) return 0;

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        uint256 numerator = amountInWithFee * resOut;
        uint256 denominator = (resIn * FEE_DENOMINATOR) + amountInWithFee;
        return numerator / denominator;
    }

    /// @notice Seeds or adds liquidity to the testnet pool and emits Sync + PriceUpdated.
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        _safeTransferFrom(token0, msg.sender, address(this), amount0);
        _safeTransferFrom(token1, msg.sender, address(this), amount1);

        _updateReserves();
        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    /// @notice Swaps exact input of token0->token1 (zeroForOne=true) or token1->token0 (zeroForOne=false).
    function swapExactIn(
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (reserve0 == 0 || reserve1 == 0) revert InsufficientLiquidity();

        amountOut = getAmountOut(zeroForOne, amountIn);
        if (amountOut == 0 || amountOut < minAmountOut) revert SlippageExceeded();

        if (zeroForOne) {
            if (amountOut >= reserve1) revert InsufficientLiquidity();
            _safeTransferFrom(token0, msg.sender, address(this), amountIn);
            _safeTransfer(token1, recipient, amountOut);
        } else {
            if (amountOut >= reserve0) revert InsufficientLiquidity();
            _safeTransferFrom(token1, msg.sender, address(this), amountIn);
            _safeTransfer(token0, recipient, amountOut);
        }

        _updateReserves();
        emit Swap(msg.sender, recipient, zeroForOne, amountIn, amountOut);
    }

    function _updateReserves() internal {
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        if (bal0 > type(uint112).max || bal1 > type(uint112).max) revert ReserveOverflow();

        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        uint64 ts = uint64(block.timestamp);
        lastUpdateTimestamp = ts;

        emit Sync(reserve0, reserve1);
        emit PriceUpdated(spotPriceE18(), bal0, bal1, ts);
    }

    function _safeTransfer(IERC20Minimal token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20Minimal token, address from, address to, uint256 amount) internal {
        if (!token.transferFrom(from, to, amount)) revert TransferFailed();
    }
}
