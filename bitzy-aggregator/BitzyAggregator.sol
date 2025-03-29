// SPDX-License-Identifier: MIT

pragma solidity =0.8.16;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

import './AggregatorDexTrader.sol';
import '../lib/Multicall.sol';

contract BitzyAggregator is Initializable, UUPSUpgradeable, OwnableUpgradeable, Multicall {
    using SafeERC20 for IERC20;
    using Address for address;

    address payable public _FEE_WALLET_ADDR_;
    address public _WETH_;

    /*
    /////////////////////////////////////////
    ///////////////// EVENT /////////////////
    /////////////////////////////////////////
    */
    event Swapped(
        address indexed srcToken,
        address indexed dstToken,
        uint256 amountIn,
        uint256 returnAmount
    );
    event SwappedSplit(
        address indexed srcToken,
        address indexed dstToken,
        uint256 amountIn,
        uint256 returnAmount
    );
    event CollectFee(
        address indexed to,
        address indexed feeToken,
        uint256 feeAmount
    );
    event SwappedStopLimit(
        address indexed srcToken,
        address indexed dstToken,
        uint256 amountIn,
        uint256 returnAmount
    );
    event CollectFeeStopLimit(
        address indexed to,
        address indexed feeToken,
        uint256 feeAmount
    );
    event FeeWalletUpdated(address newFeeWallet);
    event WETHUpdated(address newWETH);

    /*
    /////////////////////////////////////////////////
    ///////////////// CONFIGURATION /////////////////
    /////////////////////////////////////////////////
    */
    constructor() initializer {}

    function initialize(
        address _ownerAddress,
        address payable _feeWalletAddress,
        address _weth
    ) public initializer {
        __Ownable_init();
        transferOwnership(_ownerAddress);
        __UUPSUpgradeable_init();
        _FEE_WALLET_ADDR_ = _feeWalletAddress;
        _WETH_ = _weth;
    }

    fallback() external payable {}

    receive() external payable {}

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function updateConfig(
        address payable _feeWalletAddress,
        address _weth
    ) public onlyOwner {
        _FEE_WALLET_ADDR_ = _feeWalletAddress;
        _WETH_ = _weth;
    }

    /*
    /////////////////////////////////////////////
    ///////////////// DEX TRADING ///////////////
    ////////////////////////////////////////////
    */

   function splitTrade(
        address srcToken,
        address dstToken,
        uint256 amountInTotal,
        uint256 amountOutMin,
        bool isRouterSource,
        AggregatorDexTrader.TradeDescription[] calldata descTotal,
        address to
    ) external payable {
        require(amountInTotal > 0, 'Amount-in needs to be more than zero');
        require(
            amountOutMin > 0,
            'Amount-out minimum needs to be more than zero'
        );

        if (AggregatorDexTrader._ETH_ == srcToken) {
            require(
                amountInTotal == msg.value,
                'Ether value not match amount-in'
            );
            require(
                isRouterSource,
                'Source token Ether requires isRouterSource=true'
            );
        }

        uint256 beforeSrcAmt = AggregatorDexTrader._getBalance(
            srcToken,
            msg.sender
        );
        uint256 beforeDstAmt = AggregatorDexTrader._getBalance(
            dstToken,
            to
        );

        uint256 receivedAmt = 0;
        for (uint i = 0; i < descTotal.length; i++) {
            AggregatorDexTrader.TradeDescription calldata desc = descTotal[i];
            AggregatorDexTrader.TradeData memory data = AggregatorDexTrader.TradeData({
                amountIn: desc.amountIn,
                weth: _WETH_
            });
            if (AggregatorDexTrader._ETH_ == srcToken) {
                AggregatorDexTrader._wrapEther(_WETH_, desc.amountIn);
            }
            if (desc.isSourceFee) {
                if (AggregatorDexTrader._ETH_ == srcToken) {
                    data.amountIn = _collectFee(
                        data,
                        false,
                        desc.amountIn,
                        desc.srcToken
                    );
                } else {
                    data.amountIn = _collectFee(
                        data,
                        true,
                        desc.amountIn,
                        desc.srcToken
                    );
                }
            }

            // trade
            uint256 returnAmount = _trade(desc, data, true);
            receivedAmt = receivedAmt + returnAmount; 
        }

        // transfer amountOut to user
        if (receivedAmt > 0) {
            if (AggregatorDexTrader._ETH_ == dstToken) {
                uint256 ethAmount = AggregatorDexTrader._getBalance(
                    dstToken,
                    address(this)
                );
                (bool sent, ) = to.call{value: ethAmount}('');
                require(sent, 'Failed to send Ether');
            } else {
                IERC20(dstToken).safeTransfer(to, receivedAmt);
            }
        }
        
        uint256 receivedAmtLast = AggregatorDexTrader._getBalance(
            dstToken,
            to
        ) - beforeDstAmt;
        require(
            receivedAmtLast >= amountOutMin,
            'Received token is not enough'
        );

        if (srcToken != AggregatorDexTrader._ETH_) {
            uint256 afterSrcAmt = AggregatorDexTrader._getBalance(
                srcToken,
                msg.sender
            );
            require(
                beforeSrcAmt - afterSrcAmt <= amountInTotal,
                'Paid token exceeds amount-in'
            );
        }
       
        emit SwappedSplit(srcToken, dstToken, amountInTotal, receivedAmt);
    }

    function trade(
        AggregatorDexTrader.TradeDescription calldata desc
    ) external payable {
        require(desc.amountIn > 0, 'Amount-in needs to be more than zero');
        require(
            desc.amountOutMin > 0,
            'Amount-out minimum needs to be more than zero'
        );
        if (AggregatorDexTrader._ETH_ == desc.srcToken) {
            require(
                desc.amountIn == msg.value,
                'Ether value not match amount-in'
            );
            require(
                desc.isRouterSource,
                'Source token Ether requires isRouterSource=true'
            );
        }

        uint256 beforeSrcAmt = AggregatorDexTrader._getBalance(
            desc.srcToken,
            msg.sender
        );
        uint256 beforeDstAmt = AggregatorDexTrader._getBalance(
            desc.dstToken,
            desc.to
        );

        AggregatorDexTrader.TradeData memory data = AggregatorDexTrader.TradeData({
            amountIn: desc.amountIn,
            weth: _WETH_
        });
        if (desc.isSourceFee) {
            if (AggregatorDexTrader._ETH_ == desc.srcToken) {
                data.amountIn = _collectFee(
                    data,
                    false,
                    desc.amountIn,
                    desc.srcToken
                );
            } else {
                data.amountIn = _collectFee(
                    data,
                    true,
                    desc.amountIn,
                    desc.srcToken
                );
            }
        }

        uint256 returnAmount = _trade(desc, data, false);

        if (!desc.isSourceFee) {
            require(
                returnAmount >= desc.amountOutMin && returnAmount > 0,
                'Return amount is not enough'
            );
            returnAmount = _collectFee(
                data,
                false,
                returnAmount,
                desc.dstToken
            );
        }

        if (returnAmount > 0) {
            if (AggregatorDexTrader._ETH_ == desc.dstToken) {
                (bool sent, ) = desc.to.call{value: returnAmount}('');
                require(sent, 'Failed to send Ether');
            } else {
                IERC20(desc.dstToken).safeTransfer(desc.to, returnAmount);
            }
        }

        uint256 receivedAmt = AggregatorDexTrader._getBalance(
            desc.dstToken,
            desc.to
        ) - beforeDstAmt;
        require(
            receivedAmt >= desc.amountOutMin,
            'Received token is not enough'
        );

        if (desc.srcToken != AggregatorDexTrader._ETH_) {
            uint256 afterSrcAmt = AggregatorDexTrader._getBalance(
                desc.srcToken,
                msg.sender
            );
            require(
                beforeSrcAmt - afterSrcAmt <= desc.amountIn,
                'Paid token exceeds amount-in'
            );
        }

        emit Swapped(desc.srcToken, desc.dstToken, desc.amountIn, receivedAmt);
    }

    function _trade(
        AggregatorDexTrader.TradeDescription calldata desc,
        AggregatorDexTrader.TradeData memory data,
        bool isSplit
    ) internal returns (uint256 returnAmount) {
        if (desc.isRouterSource && AggregatorDexTrader._ETH_ != desc.srcToken) {
            if(_WETH_ != desc.srcToken || !isSplit){
                data.amountIn = AggregatorDexTrader._transferFromSender(
                    desc.srcToken,
                    address(this),
                    data.amountIn,
                    desc.srcToken,
                    data
                );
            }
        }
        if (AggregatorDexTrader._ETH_ == desc.srcToken && !isSplit) {
            AggregatorDexTrader._wrapEther(_WETH_, address(this).balance);
        }

        for (uint256 i = 0; i < desc.routes.length; i++) {
            data = AggregatorDexTrader._tradeRoute(
                desc.routes[i],
                desc,
                data
            );
        }

        if (AggregatorDexTrader._ETH_ == desc.dstToken) {
            returnAmount = IERC20(_WETH_).balanceOf(address(this));
            AggregatorDexTrader._unwrapEther(_WETH_, returnAmount);
        } else {
            returnAmount = IERC20(desc.dstToken).balanceOf(address(this));
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external {
        AggregatorDexTrader.UniswapV3CallbackData memory data = abi.decode(
            _data,
            (AggregatorDexTrader.UniswapV3CallbackData)
        );
        IUniswapV3Pool pool = LPV3CallbackValidation.verifyCallback(
            data.factory,
            data.token0,
            data.token1,
            data.fee
        );
        require(
            address(pool) == msg.sender,
            'UV3Callback: msg.sender is not UniswapV3 Pool'
        );
        if (amount0Delta > 0) {
            IERC20(data.token0).safeTransfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20(data.token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    /*

    /////////////////////////////////////////////////
    ///////////////// FEE COLLECTING ////////////////
    ////////////////////////////////////////////////
    */

    function _collectFee(
        AggregatorDexTrader.TradeData memory data,
        bool isTransferedFromSender,
        uint256 amount,
        address token
    ) internal returns (uint256 remainingAmount) {
        uint256 fee = _calculateFee(amount);
        require(fee < amount, 'Fee exceeds amount');
        remainingAmount = amount - fee;
        if (isTransferedFromSender) {
            remainingAmount = AggregatorDexTrader._transferFromSender(
                token,
                _FEE_WALLET_ADDR_,
                fee,
                token,
                data
            );
        } else {
            if (AggregatorDexTrader._ETH_ == token) {
                (bool sent, ) = _FEE_WALLET_ADDR_.call{value: fee}('');
                require(sent, 'Failed to send Ether too fee');
            } else {
                IERC20(token).safeTransfer(_FEE_WALLET_ADDR_, fee);
            }
        }
        emit CollectFee(_FEE_WALLET_ADDR_, token, fee);
    }

    function _calculateFee(uint256 amount) internal pure returns (uint256 fee) {
        return amount / 1000;
    }

}
