// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "../router/interfaces/INonfungiblePositionManager.sol";
import "../memeland/interfaces/IBitzyTokenGenerator.sol";

contract BitzyFeeCollector is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public positionManager;
    address public tokenGenerator;
    address public wbtc;
    address public feeTo;
    mapping(address => bool) public admin;
    mapping(address => uint256) public positionId;

    // constant address
    uint256 private constant NATIVE_AMOUNT_LP = 137_240_000_000_000_000;
    uint256 private constant TOKEN_AMOUNT_LP = 206_900_000;
    uint128 private constant MAX_AMOUNT = 340282366920938463463374607431768211455;

    event AdminUpdated(address indexed admin, bool status);
    event MigratedAndAddLp(address indexed admin, address indexed token);

    /**
     * @dev Only admin can call functions marked by this modifier.
     */
    modifier onlyAdmin(address caller) {
        require(admin[caller], 'Only admin!');
        _;
    }

    constructor(
        address feeTo_,
        address positionManager_, 
        address tokenGenerator_,
        address wbtc_
    ) {
        feeTo = feeTo_;
        admin[msg.sender] = true;
        positionManager = positionManager_;
        tokenGenerator = tokenGenerator_;
        wbtc = wbtc_;
    }

    /**
     * @notice Update admin status
     * @param _admin address Address of the admin
     * @param _status bool status of admin
     */
    function updateAdmin(address _admin, bool _status) external onlyAdmin(msg.sender) {
        admin[_admin] = _status;
        emit AdminUpdated(_admin, _status);
    }

    /**
     * @notice Migrate token and add lp
     * @param _token address Address of token
     */
    function migrateAndAddLp(address _token) external onlyAdmin(msg.sender) {
        
        IERC20 token = IERC20(_token);
        IBitzyTokenGenerator generator = IBitzyTokenGenerator(tokenGenerator);
        generator.migratePoolLp(_token);
        uint256 tokenBalances = token.balanceOf(address(this));
        uint256 nativeBalances = address(this).balance;
        uint8 decimals = generator.tokens(generator.pools(address(token)).poolId).decimals;

        uint256 tokenAmountIn = TOKEN_AMOUNT_LP.mul(10**decimals);
        require(tokenBalances > tokenAmountIn, "token not enough.");
        require(nativeBalances > NATIVE_AMOUNT_LP, "native not enough.");

        // add lp
        (address token0, address token1, uint256 amount0, uint256 amount1) = address(token) < wbtc ? 
            (address(token), wbtc, tokenAmountIn, NATIVE_AMOUNT_LP) : (wbtc, address(token), NATIVE_AMOUNT_LP, tokenAmountIn);
        INonfungiblePositionManager v3Manager = INonfungiblePositionManager(positionManager);
        token.safeApprove(positionManager, tokenBalances);
        v3Manager.mint{value: NATIVE_AMOUNT_LP}(INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: 10000,
            tickLower: -887200,
            tickUpper: 887200,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min:0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 900
        }));

        uint256 balancePos = v3Manager.balanceOf(address(this));
        uint256 posId = v3Manager.tokenOfOwnerByIndex(address(this), balancePos > 0 ? balancePos - 1 : 0);
        positionId[address(token)] = posId;
        emit MigratedAndAddLp(msg.sender, address(token));

    }

    /**
     * @notice Collect Fee from lp provided in v3 pool
     * @param _token address Address of token
     */
    function collectFee(address _token) external onlyAdmin(msg.sender) {
        INonfungiblePositionManager v3Manager = INonfungiblePositionManager(positionManager);
        uint256 position = positionId[_token];
        v3Manager.collect(INonfungiblePositionManager.CollectParams({
            tokenId: position,
            recipient: feeTo,
            amount0Max: MAX_AMOUNT,
            amount1Max: MAX_AMOUNT
        }));
    }

    receive() external payable {}
}
