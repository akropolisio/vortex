// SPDX-License-Identifier: AGPL V3.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../interfaces/IMCLP.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IBasisVault.sol";

/**
 * @title  BasisStrategy
 * @author akropolis.io
 * @notice A strategy used to perform basis trading using funds from a BasisVault
 */
contract BasisStrategy is Pausable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // struct to store the position state of the strategy
    struct Positions {
        uint256 shortPosition;
        uint256 longPosition;
        uint256 bufferPosition;
        int256 marginCash;
        int256 perpContracts;
    }

    // MCDEX Liquidity and Perpetual Pool interface address
    IMCLP public mcLiquidityPool;
    // Uniswap v3 pair pool interface address
    IUniswapV3Pool public pool;
    // Uniswap v3 router interface address
    ISwapRouter public immutable router;
    // Basis Vault interface address
    IBasisVault public vault;
    // MCDEX oracle
    IOracle public oracle;

    // address of the want (short collateral) of the strategy
    address public want;
    // address of the long asset of the strategy
    address public long;
    // address of the referrer for MCDEX
    address public referrer;
    // address of governance
    address public governance;
    // Positions of the strategy
    Positions public positions;
    // perpetual index in MCDEX
    uint256 public perpetualIndex;
    // margin buffer of the strategy, between 0 and 10_000
    uint256 public buffer;
    // max bips
    uint256 public MAX_BPS = 10_000;
    // slippage Tolerance for the perpetual trade
    int256 public slippageTolerance;

    // modifier to check that the caller is governance
    modifier onlyGovernance() {
        require(msg.sender == governance, "!governance");
        _;
    }

    // modifier to check that the caller is the vault
    modifier onlyVault() {
        require(msg.sender == address(vault), "!vault");
        _;
    }

    /**
     * @param _long            address of the long asset of the strategy
     * @param _pool            Uniswap v3 pair pool address
     * @param _vault           Basis Vault address
     * @param _oracle          MCDEX oracle address
     * @param _router          Uniswap v3 router address
     * @param _governance      Governance address
     * @param _mcLiquidityPool MCDEX Liquidity and Perpetual Pool address
     * @param _perpetualIndex  index of the perpetual market
     */
    constructor(
        address _long,
        address _pool,
        address _vault,
        address _oracle,
        address _router,
        address _governance,
        address _mcLiquidityPool,
        uint256 _perpetualIndex
    ) {
        require(_long != address(0), "!_long");
        require(_pool != address(0), "!_pool");
        require(_vault != address(0), "!_vault");
        require(_oracle != address(0), "!_oracle");
        require(_router != address(0), "!_router");
        require(_governance != address(0), "!_governance");
        require(_mcLiquidityPool != address(0), "!_mcLiquidityPool");
        long = _long;
        pool = IUniswapV3Pool(_pool);
        vault = IBasisVault(_vault);
        oracle = IOracle(_oracle);
        router = ISwapRouter(_router);
        governance = _governance;
        mcLiquidityPool = IMCLP(_mcLiquidityPool);
        perpetualIndex = _perpetualIndex;
        want = address(vault.want());
    }

    /**********
     * EVENTS *
     **********/

    event DepositToMarginAccount(uint256 amount, uint256 perpetualIndex);
    event Harvest(
        uint256 shortPosition,
        uint256 longPosition,
        uint256 bufferPosition
    );
    event StrategyUnwind(uint256 positionSize, uint256 unwindTime);
    event EmergencyExit(
        address indexed recipient,
        uint256 positionSize,
        uint256 exitTime
    );
    event PerpPositionOpened(
        int256 perpPositions,
        uint256 perpetualIndex,
        uint256 collateral
    );

    /***********
     * SETTERS *
     ***********/

    /**
     * @notice  setter for the mcdex liquidity pool
     * @param   _mcLiquidityPool MCDEX Liquidity and Perpetual Pool address
     * @dev     only callable by owner
     */
    function setLiquidityPool(address _mcLiquidityPool) external onlyOwner {
        mcLiquidityPool = IMCLP(_mcLiquidityPool);
    }

    /**
     * @notice  setter for the uniswap pair pool
     * @param   _pool Uniswap v3 pair pool address
     * @dev     only callable by owner
     */
    function setUniswapPool(address _pool) external onlyOwner {
        pool = IUniswapV3Pool(_pool);
    }

    /**
     * @notice  setter for the basis vault
     * @param   _vault Basis Vault address
     * @dev     only callable by owner
     */
    function setBasisVault(address _vault) external onlyOwner {
        vault = IBasisVault(_vault);
    }

    /**
     * @notice  setter for buffer
     * @param   _buffer Basis strategy margin buffer
     * @dev     only callable by owner
     */
    function setBuffer(uint256 _buffer) external onlyOwner {
        require(_buffer < 10_000, "!_buffer");
        buffer = _buffer;
    }

    /**
     * @notice  setter for perpetualIndex value
     * @param   _perpetualIndex MCDEX perpetual index
     * @dev     only callable by owner
     */
    function setPerpetualIndex(uint256 _perpetualIndex) external onlyOwner {
        perpetualIndex = _perpetualIndex;
    }

    /**
     * @notice  setter for referrer for MCDEX rebates
     * @param   _referrer address of the MCDEX referral recipient
     * @dev     only callable by owner
     */
    function setReferrer(address _referrer) external onlyOwner {
        referrer = _referrer;
    }

    /**
     * @notice  setter for perpetual trade slippage tolerance
     * @param   _slippageTolerance amount of slippage tolerance to accept on perp trade
     * @dev     only callable by owner
     */
    function setSlippageTolerance(int256 _slippageTolerance)
        external
        onlyOwner
    {
        slippageTolerance = _slippageTolerance;
    }

    /**
     * @notice  setter for the governance address
     * @param   _governance address of governance
     * @dev     only callable by governance
     */
    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    /**********************
     * EXTERNAL FUNCTIONS *
     **********************/

    /**
     * @notice  harvest the strategy. This involves accruing profits from the strategy and depositing
     *          user funds to the strategy. The funds are split into their constituents and then distributed
     *          to their appropriate location.
     *          For the shortPosition a perpetual position is opened, for the long position funds are swapped
     *          to the long asset. For the buffer position the funds are deposited to the margin account idle.
     * @dev     only callable by the owner
     */
    function harvest() external onlyOwner {
        uint256 shortPosition;
        uint256 longPosition;
        uint256 bufferPosition;
        // determine the profit since the last harvest and remove profits from the margi
        // account to be redistributed
        (uint256 amount, bool loss) = _determineFee();
        // record a loss in the short position if there is one
        positions.shortPosition -= loss ? amount : 0;
        // update the vault with profits/losses accrued and receive deposits
        uint256 newFunds = vault.update(amount, loss);
        // combine the funds and check that they are larger than 0
        uint256 toActivate = loss ? newFunds : newFunds + amount;

        if (toActivate > 0) {
            // determine the split of the funds and trade for the spot position of long
            (shortPosition, longPosition, bufferPosition) = _calculateSplit(
                toActivate
            );
            // deposit the bufferPosition to the margin account
            _depositToMarginAccount(bufferPosition);
            // open a short perpetual position and store the number of perp contracts
            positions.perpContracts += _openPerpPosition(shortPosition);
            // record incremented positions
            positions.shortPosition += shortPosition;
            positions.longPosition += longPosition;
            positions.bufferPosition += bufferPosition;
            positions.marginCash = getMarginCash();
        }
        emit Harvest(shortPosition, longPosition, bufferPosition);
    }

    /**
     * @notice  unwind the position in adverse funding rate scenarios, settle short position
     *          and pull funds from the margin account. Then converts the long position back
     *          to want.
     * @dev     only callable by the owner
     */
    function unwind() public onlyOwner {
        // settle short perpetual position
        mcLiquidityPool.settle(perpetualIndex, address(this));
        // swap long asset back to want
        _swap(IERC20(long).balanceOf(address(this)), long, want);
        // withdraw all cash in the margin account
        mcLiquidityPool.withdraw(
            perpetualIndex,
            address(this),
            getMarginCash()
        );
        // reset positions
        positions.bufferPosition = 0;
        positions.longPosition = 0;
        positions.shortPosition = 0;
        positions.marginCash = 0;
        positions.perpContracts = 0;
        emit StrategyUnwind(
            IERC20(want).balanceOf(address(this)),
            block.timestamp
        );
    }

    /**
     * @notice  emergency exit the entire strategy in extreme circumstances
     *          unwind the strategy and send the funds to governance
     * @dev     only callable by governance
     */
    function emergencyExit() external onlyGovernance {
        // unwind strategy
        unwind();
        // send funds to governance
        IERC20(want).safeTransfer(
            governance,
            IERC20(want).balanceOf(address(this))
        );
        emit EmergencyExit(
            governance,
            IERC20(want).balanceOf(address(this)),
            block.timestamp
        );
    }

    function withdraw() external onlyVault {}

    function tend() external onlyOwner {}

    /**********************
     * INTERNAL FUNCTIONS *
     **********************/

    /**
     * @notice  open the perpetual short position on MCDEX
     * @param   _amount the collateral used to purchase the perpetual short position
     * @return  tradeAmount the amount of perpetual contracts opened
     */
    function _openPerpPosition(uint256 _amount)
        internal
        returns (int256 tradeAmount)
    {
        // deposit funds to the margin account to enable trading
        _depositToMarginAccount(_amount);
        // get the long asset mark price from the MCDEX oracle
        (int256 price, ) = oracle.priceTWAPLong();
        // calculate the number of contracts (*1e12 because USDC is 6 decimals)
        int256 contracts = ((int256(_amount) * 1e12) * 1e18) / price;
        // open short position
        tradeAmount = mcLiquidityPool.trade(
            perpetualIndex,
            address(this),
            -contracts,
            price + slippageTolerance,
            block.timestamp,
            referrer,
            0
        );
        emit PerpPositionOpened(tradeAmount, perpetualIndex, _amount);
    }

    /**
     * @notice  deposit to the margin account without opening a perpetual position
     * @param   _amount the amount to deposit into the margin account
     */
    function _depositToMarginAccount(uint256 _amount) internal {
        IERC20(want).approve(address(mcLiquidityPool), _amount);
        mcLiquidityPool.deposit(perpetualIndex, address(this), int256(_amount));
        emit DepositToMarginAccount(_amount, perpetualIndex);
    }

    /**
     * @notice  determine the funding premiums that have been collected since the last epoch
     * @return  fee  the funding rate premium collected since the last epoch
     * @return  loss whether the funding rate was a loss or not
     */
    function _determineFee() internal returns (uint256 fee, bool loss) {
        int256 feeInt;
        // get the cash held in the margin cash, funding rates are saved as cash in the margin account
        int256 newMarginCash = getMarginCash();
        int256 oldMarginCash = positions.marginCash;
        if (oldMarginCash > newMarginCash) {
            // if the margin cash held has gone down then record a loss
            loss = true;
            feeInt = oldMarginCash - newMarginCash;
        } else {
            // if the margin cash held has gone up then record a profit and withdraw the excess for redistribution
            feeInt = newMarginCash - oldMarginCash;
            mcLiquidityPool.withdraw(perpetualIndex, address(this), feeInt);
        }
        fee = uint256(feeInt);
    }

    /**
     * @notice  split an amount of assets into three:
     *          the short position which represents the short perpetual position
     *          the long position which represents the long spot position
     *          the buffer position which represents the funds to be left idle in the margin account
     * @param   _amount the amount to be split in want
     * @return  shortPosition  the size of the short perpetual position in want
     * @return  longPosition   the size of the long spot position in long
     * @return  bufferPosition the size of the buffer position in want
     */
    function _calculateSplit(uint256 _amount)
        internal
        returns (
            uint256 shortPosition,
            uint256 longPosition,
            uint256 bufferPosition
        )
    {
        require(_amount > 0, "_calculateSplit: _amount is 0");
        // remove the buffer from the amount
        bufferPosition = (_amount * buffer) / MAX_BPS;
        // decrement the amount by buffer position
        _amount -= bufferPosition;
        // determine the longPosition in want then convert it to long
        uint256 longPositionWant = _amount / 2;
        longPosition = _swap(longPositionWant, want, long);
        // determine the short position
        shortPosition = _amount - longPositionWant;
    }

    /**
     * @notice  swap function using uniswapv3 to facilitate the swap from want to long
     * @param   _amount    the amount to be swapped in want
     * @param   _tokenIn   the asset sent in
     * @param   _tokenOut  the asset taken out
     * @return  amountOut the amount of long returned in exchange for the amount of want
     */
    function _swap(
        uint256 _amount,
        address _tokenIn,
        address _tokenOut
    ) internal returns (uint256 amountOut) {
        // set up swap params
        uint256 deadline = block.timestamp;
        address tokenIn = _tokenIn;
        address tokenOut = _tokenOut;
        uint24 fee = pool.fee();
        address recipient = msg.sender;
        uint256 amountIn = _amount;
        uint256 amountOutMinimum = 0;
        uint160 sqrtPriceLimitX96 = 0;
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams(
                tokenIn,
                tokenOut,
                fee,
                recipient,
                deadline,
                amountIn,
                amountOutMinimum,
                sqrtPriceLimitX96
            );
        // approve the router to spend the tokens
        IERC20(_tokenIn).approve(address(router), _amount);
        // swap optimistically via the uniswap v3 router
        amountOut = router.exactInputSingle(params);
    }

    function _closePerpPosition() internal {}

    /***********
     * GETTERS *
     ***********/

    /**
     * @notice  getter for the MCDEX margin account cash balance of the strategy
     * @return  cash of the margin account
     */
    function getMarginCash() public view returns (int256 cash) {
        (cash, , , , , , , , ) = mcLiquidityPool.getMarginAccount(
            perpetualIndex,
            address(this)
        );
    }
}
