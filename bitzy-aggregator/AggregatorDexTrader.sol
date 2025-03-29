// SPDX-License-Identifier: MIT

pragma solidity =0.8.16;
pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

import '../interfaces/IWETH.sol';

import '../lib/LPV2Library.sol';
import '../lib/LPV3CallbackValidation.sol';

library AggregatorDexTrader {
    using SafeERC20 for IERC20;

    // CONSTANTS
    uint256 constant _MAX_UINT_256_ = 2 ** 256 - 1;
    // Uniswap V3
    uint160 public constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 public constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342 - 1;
    address public constant _ETH_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    enum RouterInterface {
        UNISWAP_V2,
        UNISWAP_V3
    }

    struct TradeRoute {
        address routerAddress;
        address lpAddress;
        address fromToken;
        address toToken;
        address from;
        address to;
        uint32 part;
        uint16 amountAfterFee; // 9970 = fee 0.3% -- 10000 = no fee
        RouterInterface dexInterface; // uint8
    }
    struct TradeDescription {
        address srcToken;
        address dstToken;
        uint256 amountIn;
        uint256 amountOutMin;
        address payable to;
        TradeRoute[] routes;
        bool isRouterSource;
        bool isSourceFee;
    }
    struct TradeData {
        uint256 amountIn;
        address weth;
    }
    struct UniswapV3CallbackData {
        address factory;
        address token0;
        address token1;
        uint24 fee;
    }

    function _tradeRoute(
        TradeRoute calldata route,
        TradeDescription calldata desc,
        TradeData memory data
    ) public returns (TradeData memory) {
        require(
            route.part <= 100000000,
            'Route percentage can not exceed 100000000'
        );
        require(
            route.fromToken != _ETH_ && route.toToken != _ETH_,
            'TradeRoute from/to token cannot be Ether'
        );
        if (route.from == address(1)) {
            require(
                route.fromToken == desc.srcToken,
                'Cannot transfer token from msg.sender'
            );
        }
        if (
            !desc.isSourceFee &&
            (route.toToken == desc.dstToken ||
                (_ETH_ == desc.dstToken && data.weth == route.toToken))
        ) {
            require(
                route.to == address(0),
                'Destination swap have to be ArkenDex'
            );
        }
        uint256 amountIn;
        if (route.from == address(0)) {
            amountIn =
                (IERC20(route.fromToken).balanceOf(address(this)) * route.part) / 100000000;
        } else if (route.from == address(1)) {
            amountIn = (data.amountIn * route.part) / 100000000;
        }
        if (route.dexInterface == RouterInterface.UNISWAP_V2) {
            _tradeUniswapV2(route, amountIn, desc, data);
        } else if (route.dexInterface == RouterInterface.UNISWAP_V3) {
            _tradeUniswapV3(route, amountIn, desc);
        } else {
            revert('unknown router interface');
        }
        return data;
    }

    function _tradeUniswapV2(
        TradeRoute calldata route,
        uint256 amountIn,
        TradeDescription calldata desc,
        TradeData memory data
    ) public {
        if (route.from == address(0)) {
            IERC20(route.fromToken).safeTransfer(route.lpAddress, amountIn);
        } else if (route.from == address(1)) {
            data.amountIn = _transferFromSender(
                route.fromToken,
                route.lpAddress,
                amountIn,
                desc.srcToken,
                data
            );
        }
        IUniswapV2Pair pair = IUniswapV2Pair(route.lpAddress);
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint256 reserveFrom, uint256 reserveTo) = route.fromToken ==
            pair.token0()
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        amountIn =
            IERC20(route.fromToken).balanceOf(route.lpAddress) -
            reserveFrom;
        uint256 amountOut = LPV2Library.getAmountOut(
            amountIn,
            reserveFrom,
            reserveTo,
            route.amountAfterFee
        );
        address to = route.to;
        if (to == address(0)) to = address(this);
        if (to == address(1)) to = desc.to;
        if (route.toToken == pair.token0()) {
            pair.swap(amountOut, 0, to, '');
        } else {
            pair.swap(0, amountOut, to, '');
        }
    }

    function _tradeUniswapV3(
        TradeRoute calldata route,
        uint256 amountIn,
        TradeDescription calldata desc
    ) public {
        require(route.from == address(0), 'route.from should be zero address');
        IUniswapV3Pool pool = IUniswapV3Pool(route.lpAddress);
        bool zeroForOne = pool.token0() == route.fromToken;
        address to = route.to;
        if (to == address(0)) to = address(this);
        if (to == address(1)) to = desc.to;
        pool.swap(
            to,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO : MAX_SQRT_RATIO,
            abi.encode(
                UniswapV3CallbackData({
                    factory: pool.factory(),
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee()
                })
            )
        );
    }

    function _increaseAllowance(
        address token,
        address spender,
        uint256 amount
    ) public {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (amount > allowance) {
            uint256 increaseAmount = _MAX_UINT_256_ - allowance;
            IERC20(token).safeIncreaseAllowance(spender, increaseAmount);
        }
    }

    function _transferFromSender(
        address token,
        address to,
        uint256 amount,
        address srcToken,
        TradeData memory data
    ) public returns (uint256 newAmountIn) {
        newAmountIn = data.amountIn - amount;
        if (srcToken != _ETH_) {
            IERC20(token).transferFrom(msg.sender, to, amount);
        } else {
            _wrapEther(data.weth, amount);
            if (to != address(this)) {
                IERC20(data.weth).safeTransfer(to, amount);
            }
        }
    }

    function _wrapEther(address weth, uint256 amount) public {
        IWETH(weth).deposit{value: amount}();
    }

    function _unwrapEther(address weth, uint256 amount) public {
        IWETH(weth).withdraw(amount);
    }

    function _getBalance(
        address token,
        address account
    ) public view returns (uint256) {
        if (_ETH_ == token) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }
}
