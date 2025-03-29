// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20PausableUpgradeable.sol";
import "../libs/sqrtMath.sol";
import "../BitzyCustomToken.sol";
import "../../router/interfaces/INonfungiblePositionManager.sol";
import '../../interfaces/IUniswapV3Factory.sol';

contract BitzyTokenGeneratorUpgradable is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using sqrtMath for uint256;

    struct TokenInfo {
        uint32 poolId;
        address token;
        uint8 decimals;
    }

    struct PoolInfo {
        uint32 poolId;
        uint256 initialTokenSupply;
        uint256 virtualReserveNative;
        uint256 virtualReserveToken;
        uint256 nativeBalances;
        uint256 tokenBalances;
        bool migrationStatus;
        bool available;
    }

    // constant address
    address private constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000;
    uint256 private constant FEE_DENOMINATOR = 1000000;

    // cap threshold and virtual price of token
    uint256 public MIGRATION_THRESHOLD;
    uint256 public INITIAL_VIRTUAL_NATIVE;
    uint256 public INITIAL_VIRTUAL_TOKEN;

    // fee rate
    uint256 public SWAP_FEE;
    uint256 public MIGRATE_FEE;

    address public MIGRATE_ROUTER;
    uint32 public poolLength;
    mapping(uint32 => TokenInfo) public tokens;
    mapping(address => PoolInfo) public pools;
    mapping(address => bool) public admin;
    address public feeTo;

    event TokenCreated( 
        uint256 indexed poolIndex, 
        address indexed tokenAddress, 
        address indexed user,
        string ref
    );
    event Migrated(address indexed admin, address indexed token, uint256 nativeAmount, uint256 tokenAmount);
    event ReachMilestone(address indexed token, uint32 indexed poolId);
    event Swapped(
        address indexed src, 
        address indexed dest,
        address indexed user, 
        uint256 amountIn, 
        uint256 amountOut,
        uint256 reserveNative,
        uint256 reserveToken,
        uint256 balanceNative,
        uint256 balanceToken
    );
    event AdminUpdated(address indexed admin, bool status);
    event FeeUpdated(address indexed admin, uint256 indexed feeSwap, uint256 indexed feeMigrate);
    event RouterUpdated(address indexed admin, address indexed router);

    /**
     * @dev Only admin can call functions marked by this modifier.
     */
    modifier onlyAdmin(address caller) {
        require(admin[caller], 'Only admin!');
        _;
    }

    /**
     * @dev Only pool that not reach market cap goal can call functions marked by this modifier.
     */
    modifier onlyNotFinished(uint256 amount, address src, address dest) {
        if(src == NATIVE){
            require(pools[dest].nativeBalances.add(amount) <= MIGRATION_THRESHOLD, 'Pool exceed goal cap.');
        }else{
            require(pools[src].nativeBalances < MIGRATION_THRESHOLD, 'Pool exceed goal cap.');
        }
        _;
    }

    /**
     * @notice Initialize
     * @param _admin address Address of the admin
     * @param _feeTo bool Address of fee collector
     * @param _router address Address of router for migrate lp when pool reach cap goal
     */
    function initialize(address _admin, address _feeTo, address _router) public initializer {
        __Ownable_init();
        feeTo = _feeTo;
        admin[_admin] = true;
        admin[msg.sender] = true;
        SWAP_FEE = 7500;
        MIGRATE_FEE = 12e15;
        MIGRATE_ROUTER = _router;
        MIGRATION_THRESHOLD = 15e16;
        INITIAL_VIRTUAL_NATIVE = 71e15;
        INITIAL_VIRTUAL_TOKEN = 1_168_480_000;
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
     * @notice Update swap fee
     * @param _swapfee uint256 swap fee rate
     * @param _migratefee uint256 migartion fee rate
     */
    function updateSwapFee(uint256 _swapfee, uint256 _migratefee) external onlyAdmin(msg.sender) {
        require(_swapfee < FEE_DENOMINATOR, "Invalid fee.");
        require(_migratefee < 1e18, "Invalid fee.");
        SWAP_FEE = _swapfee;
        MIGRATE_FEE = _migratefee;
        emit FeeUpdated(msg.sender, _swapfee, _migratefee);
    }

    /**
     * @notice Update swap fee
     * @dev if use function might cause effect for threshold of every pool in past and in future
     * @param _threshold uint256 goal cap for native token
     * @param _virtualnative uint256 virtual rate for initial price in native
     * @param _virtualtoken uint256 virtual rate for initial price in token
     */
    function config(uint256 _threshold, uint256 _virtualnative, uint256 _virtualtoken) external onlyOwner {
        MIGRATION_THRESHOLD = _threshold;
        INITIAL_VIRTUAL_NATIVE = _virtualnative;
        INITIAL_VIRTUAL_TOKEN = _virtualtoken;
    }

    /**
     * @notice Update migrate router
     * @param _router address Address of router for migrate lp when pool reach cap goal
     */
    function updateMigrateRouter(address _router) external onlyAdmin(msg.sender) {
        require(_router != address(0), "Invalid router.");
        MIGRATE_ROUTER = _router;
        emit RouterUpdated(msg.sender, _router);
    }

    /**
     * @notice Create new token
     * @param _name string String of token name
     * @param _symbol string String of token symbol
     * @param _decimals uint8 token decimal
     * @param _ref string reference of token
     */
    function createToken(string memory _name, string memory _symbol, uint8 _decimals, string memory _ref) external whenNotPaused {
        _createToken(_name, _symbol, _decimals, _ref);
    }

    /**
     * @notice Create new token and buy token
     * @param _name string String of token name
     * @param _symbol string String of token symbol
     * @param _decimals uint8 token decimal
     * @param _amount uint256 amount of native swap for token
     * @param _amountOutMin uint256 minimum amount of token from swap
     */
    function createTokenAndSwap(
        string memory _name, 
        string memory _symbol,  
        uint8 _decimals,
        string memory _ref,
        uint256 _amount,
        uint256 _amountOutMin
    ) external payable whenNotPaused {
        address token = _createToken(_name, _symbol, _decimals, _ref);
        swap(NATIVE, token, _amount, _amountOutMin);
    }

    /**
     * @notice Swap
     * @param _src address Address of source token for swap
     * @param _dest address Address of destination token for swap
     * @param _amount uint256 amount of native swap for token
     * @param _amountOutmin uint256 minimum amount of token from swap
     */
    function swap(
        address _src, 
        address _dest, 
        uint256 _amount, 
        uint256 _amountOutmin
    ) public payable onlyNotFinished(_amount, _src, _dest) whenNotPaused {
        require(_src != _dest, "Invalid source or destination token.");
        if(_src == NATIVE){
            _swapNative(_dest, _amount, _amountOutmin);

        }else if(_dest == NATIVE){
            _swapToken(_src, _amount, _amountOutmin);
        }
    }

    /**
     * @notice Migrate token to lp
     * @param _token address Address of token
     */
    function migratePoolLp(address _token) external onlyAdmin(msg.sender) whenNotPaused {
        PoolInfo memory poolData = pools[_token];
        require(poolData.available, "Pool status not avialable");
        require(!poolData.migrationStatus, "Only migrate once.");
        require(poolData.nativeBalances >= MIGRATION_THRESHOLD, "Must be reach milestone.");
        uint256 currNativeBalance = address(this).balance;
        uint256 currTokenBalance = IERC20(_token).balanceOf(address(this));

        require(poolData.nativeBalances <= currNativeBalance, "Not enough balance.");
        // transfer token to admin
        uint256 nativeAfterFee = poolData.nativeBalances.sub(MIGRATE_FEE);
        payable(feeTo).transfer(MIGRATE_FEE);

        IBitzyCustomToken(_token).migrated();
        
        // transfer token
        payable(msg.sender).transfer(nativeAfterFee);
        IERC20(_token).safeTransfer(msg.sender, currTokenBalance);

        // update pool info
        pools[_token].nativeBalances = 0;
        pools[_token].tokenBalances = 0;
        pools[_token].migrationStatus = true;
        pools[_token].available = false;

        emit Migrated(msg.sender, _token, poolData.nativeBalances, currTokenBalance);
    }

    /**
     * @notice Emergency withdraw (in case token stuck or emegency issue with contract)
     * @param _token address Address of destination token for swap
     * @param _amount uint256 amount of native swap for token
     */
    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner whenPaused {
        if(_token == NATIVE){
            payable(owner()).transfer(_amount);
        }else{
            IERC20(_token).safeTransfer(owner(), _amount);
        }
    }

    /**
     * @notice Calculate amount of token from swap by native
     * @param _token address Address of token output
     * @param _amount uint256 amount of token native
     */
    function getSwapToTokenAmount(address _token, uint256 _amount) public view returns (uint256, uint256, uint256) {
        PoolInfo memory poolsData = pools[_token]; 
        uint256 k = poolsData.virtualReserveNative.mul(poolsData.virtualReserveToken);
        uint256 newNativeReserve = poolsData.virtualReserveNative.add(_amount);
        uint256 newTokenReserve = k.div(newNativeReserve);

        uint256 tokenAmount = poolsData.virtualReserveToken.sub(newTokenReserve);
        return (tokenAmount, newNativeReserve, newTokenReserve);
    }

    /**
     * @notice Calculate amount of token from swap by native
     * @param _token address Address of native
     * @param _amount uint256 amount of token
     */
    function getSwapToNativeAmount(address _token, uint256 _amount) public view returns (uint256, uint256, uint256) {
        PoolInfo memory poolsData = pools[_token]; 
        uint256 k = poolsData.virtualReserveNative.mul(poolsData.virtualReserveToken); 
        uint256 newTokenReserve = poolsData.virtualReserveToken.add(_amount);
        uint256 newNativeReserve = k.div(newTokenReserve);

        uint256 tokenAmount = poolsData.virtualReserveNative.sub(newNativeReserve);
        return (tokenAmount, newNativeReserve, newTokenReserve);
    }

    function _createToken(string memory name, string memory symbol, uint8 decimals_, string memory ref) internal returns (address) {
        BitzyCustomToken token = new BitzyCustomToken(name, symbol, decimals_);
        uint256 initialSupply = INITIAL_SUPPLY.mul(10**decimals_);
        // initialize token info
        TokenInfo memory tokenInfo = TokenInfo({
            poolId: poolLength,
            token: address(token),
            decimals: decimals_
        });
        tokens[poolLength] = tokenInfo;

        // initial v3 lp
        _initializePool(address(token), decimals_);

        // initialize pool
        PoolInfo memory initPool = PoolInfo({
            poolId: poolLength,
            initialTokenSupply: initialSupply,
            virtualReserveNative: INITIAL_VIRTUAL_NATIVE,
            virtualReserveToken: INITIAL_VIRTUAL_TOKEN.mul(10**decimals_),
            nativeBalances: 0,
            tokenBalances: initialSupply,
            migrationStatus: false,
            available: true
        });
        pools[address(token)] = initPool;
        uint32 latestPoolLength = poolLength + 1;
        poolLength = latestPoolLength;

        token.mint(address(this), initialSupply);
        token.transferOwnership(DEAD);
        
        emit TokenCreated(latestPoolLength, address(token), msg.sender, ref);

        return address(token);
    }

    function _initializePool(address token, uint8 decimals) internal {
        address WRAP = INonfungiblePositionManager(MIGRATE_ROUTER).WETH9();
        uint256 NATIVE_MIGRATE_AMOUNT = 138000000000000000;
        uint256 TOKEN_MIGRATE_AMOUNT = uint256(206_900_000).mul(10**decimals);
        // uint160 sqrtpriceX96 = 3067752268132824531591528902342301;
        (address token0, address token1, uint160 sqrtPricex96) = WRAP < token ? 
            (WRAP, address(token), getSqrtPriceX96(NATIVE_MIGRATE_AMOUNT, TOKEN_MIGRATE_AMOUNT, 18, decimals)) : 
            (address(token), WRAP, getSqrtPriceX96(TOKEN_MIGRATE_AMOUNT, NATIVE_MIGRATE_AMOUNT, decimals, 18));
        INonfungiblePositionManager(MIGRATE_ROUTER).createAndInitializePoolIfNecessary(
            token0,
            token1,
            10000,
            sqrtPricex96
        );
        address factory =  INonfungiblePositionManager(MIGRATE_ROUTER).factory();
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, 10000);

        IBitzyCustomToken(token).setBlacklist(pool);

    }

    function _swapNative(address token, uint256 amount, uint256 amountOutmin) internal {

        PoolInfo memory poolData = pools[token];
        require(poolData.available, "Pool status not avialable");
        uint256 feeAmount = amount.mul(SWAP_FEE).div(FEE_DENOMINATOR);
        require(msg.value == amount.add(feeAmount) && msg.value > 0, "Invalid token amount.");
        (uint256 tokenAmount, uint256 newNative, uint256 newToken) = getSwapToTokenAmount(token, amount);
        require(tokenAmount >= amountOutmin, "Price Impact too high.");

        // update reserves and balances
        pools[token].virtualReserveNative = newNative;
        pools[token].virtualReserveToken = newToken;
        pools[token].nativeBalances = poolData.nativeBalances.add(amount);
        pools[token].tokenBalances = poolData.tokenBalances.sub(tokenAmount);

        if(pools[token].nativeBalances >= MIGRATION_THRESHOLD){
            emit ReachMilestone(token, poolData.poolId);
        }

        // Transfer token to user
        IERC20(token).safeTransfer(msg.sender, tokenAmount);
        // Transfer fee to treasury
        payable(feeTo).transfer(feeAmount);

        emit Swapped(
            NATIVE, 
            token, 
            msg.sender, 
            amount, 
            tokenAmount, 
            newNative, 
            newToken,
            poolData.nativeBalances.add(amount),
            poolData.tokenBalances.sub(tokenAmount)
        );

    }

    function _swapToken(address token, uint256 amount, uint256 amountOutmin) internal {

        require(amount > 0, "Invalid token amount.");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        PoolInfo memory poolData = pools[token];
        require(poolData.available, "Pool status not avialable");
        // case token calculate overflow
        uint256 amountCheck = amount;
        if(poolData.tokenBalances.add(amount) > poolData.initialTokenSupply){
            amountCheck = poolData.initialTokenSupply.sub(poolData.tokenBalances);
        }
        (uint256 tokenAmount, uint256 newNative, uint256 newToken) = getSwapToNativeAmount(token, amountCheck);
        uint256 feeAmount = tokenAmount.mul(SWAP_FEE).div(FEE_DENOMINATOR);
        require(tokenAmount >= amountOutmin, "Price Impact too high.");

        // case native out is greater than balance in pool
        if(poolData.nativeBalances < tokenAmount){
            tokenAmount = poolData.nativeBalances;
        }

        // update reserves and balances
        poolData.virtualReserveNative = newNative;
        poolData.virtualReserveToken = newToken;
        poolData.nativeBalances = poolData.nativeBalances.sub(tokenAmount);
        poolData.tokenBalances = poolData.tokenBalances.add(amountCheck);

        pools[token] = poolData;

        // Transfer native to user
        uint256 amountAfterFee = tokenAmount.sub(feeAmount);
        payable(msg.sender).transfer(amountAfterFee);
        // Transfer fee to treasury
        payable(feeTo).transfer(feeAmount);
        emit Swapped(
            token, 
            NATIVE, 
            msg.sender, 
            amount, 
            amountAfterFee, 
            poolData.virtualReserveNative, 
            poolData.virtualReserveToken,
            poolData.nativeBalances,
            poolData.tokenBalances
        );

    }

    function getSqrtPriceX96(
        uint256 amount0,
        uint256 amount1,
        uint8 decimal0,
        uint8 decimal1
    ) public pure returns (uint160 sqrtPriceX96) {
        // Normalize the amounts to 18 decimals
        uint256 normalizedAmount0 = amount0.mul(10 ** (18 - decimal0));
        uint256 normalizedAmount1 = amount1.mul(10 ** (18 - decimal1));

        // Calculate the price = normalizedAmount1 / normalizedAmount0
        uint256 price = normalizedAmount1.mul(10 ** 18).div(normalizedAmount0);

        // Calculate sqrt(price)
        uint256 sqrtPrice = price.sqrt();

        // Calculate sqrtPriceX96
        sqrtPriceX96 = uint160(sqrtPrice.mul(2**96).div(10 ** 9));
    }

    receive() external payable {}

}
