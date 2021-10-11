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
        int256 perpContracts;
        int256 availableMargin;
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
    uint256 public constant MAX_BPS = 10_000;
    // decimal shift for USDC
    int256 public constant DECIMAL_SHIFT = 1e12;
    // dust for margin positions
    int256 public dust = 1000;
    // slippage Tolerance for the perpetual trade
    int256 public slippageTolerance;
    // unwind state tracker
    bool public isUnwind;
    // trade mode of the perp
    uint32 public tradeMode = 0x40000000;
    // modifier to check that the caller is governance
    modifier onlyGovernance() {
        require(msg.sender == governance, "!governance");
        _;
    }

    // modifier to check that the caller is governance or owner
    modifier onlyAuthorised() {
        require(
            msg.sender == governance || msg.sender == owner(),
            "!authorised"
        );
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
        mcLiquidityPool.setTargetLeverage(perpetualIndex, address(this), 1e18);
    }

    /**********
     * EVENTS *
     **********/

    event DepositToMarginAccount(uint256 amount, uint256 perpetualIndex);
    event WithdrawStrategy(uint256 amountWithdrawn);
    event Harvest(
        int256 perpContracts,
        uint256 longPosition,
        int256 availableMargin
    );
    event StrategyUnwind(uint256 positionSize);
    event EmergencyExit(address indexed recipient, uint256 positionSize);
    event PerpPositionOpened(
        int256 perpPositions,
        uint256 perpetualIndex,
        uint256 collateral
    );
    event PerpPositionClosed(
        int256 perpPositions,
        uint256 perpetualIndex,
        uint256 collateral
    );
    event AllPerpPositionsClosed(int256 perpPositions, uint256 perpetualIndex);
    event Snapshot(
        int256 cash,
        int256 position,
        int256 availableMargin,
        int256 margin,
        int256 settleableMargin,
        bool isInitialMarginSafe,
        bool isMaintenanceMarginSafe,
        bool isMarginSafe // bankrupt
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
     * @notice  setter for dust for closing margin positions
     * @param   _dust amount of dust in wei that is acceptable
     * @dev     only callable by owner
     */
    function setDust(int256 _dust) external onlyOwner {
        dust = _dust;
    }

    /**
     * @notice  setter for the tradeMode of the perp
     * @param   _tradeMode uint32 for the perp trade mode
     * @dev     only callable by owner
     */
    function setTradeMode(uint32 _tradeMode) external onlyOwner {
        tradeMode = _tradeMode;
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
        isUnwind = false;

        mcLiquidityPool.forceToSyncState();
        // determine the profit since the last harvest and remove profits from the margi
        // account to be redistributed
        (uint256 amount, bool loss) = _determineFee();
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
            positions.availableMargin = getAvailableMargin();
        }
        emit Harvest(
            positions.perpContracts,
            IERC20(long).balanceOf(address(this)),
            positions.availableMargin
        );
    }

    /**
     * @notice  unwind the position in adverse funding rate scenarios, settle short position
     *          and pull funds from the margin account. Then converts the long position back
     *          to want.
     * @dev     only callable by the owner
     */
    function unwind() public onlyAuthorised {
        require(!isUnwind, "unwound");
        isUnwind = true;
        // close the short position
        int256 positionsClosed = _closeAllPerpPositions();
        // swap long asset back to want
        _swap(IERC20(long).balanceOf(address(this)), long, want);
        // withdraw all cash in the margin account
        mcLiquidityPool.withdraw(
            perpetualIndex,
            address(this),
            getMarginCash()
        );
        // reset positions
        positions.perpContracts = 0;
        positions.availableMargin = getAvailableMargin();
        emit StrategyUnwind(IERC20(want).balanceOf(address(this)));
    }

    /**
     * @notice  emergency exit the entire strategy in extreme circumstances
     *          unwind the strategy and send the funds to governance
     * @dev     only callable by governance
     */
    function emergencyExit() external onlyGovernance {
        // unwind strategy unless it is already unwound
        if (!isUnwind) {
            unwind();
        }
        uint256 wantBalance = IERC20(want).balanceOf(address(this));
        // send funds to governance
        IERC20(want).safeTransfer(governance, wantBalance);
        emit EmergencyExit(governance, wantBalance);
    }

    /**
     * @notice  withdraw funds from the strategy
     * @param   _amount the amount to be withdrawn
     * @return  loss loss recorded
     * @return  withdrawn amount withdrawn
     * @dev     only callable by the vault
     */
    function withdraw(uint256 _amount)
        external
        onlyVault
        returns (uint256 loss, uint256 withdrawn)
    {
        require(_amount > 0, "withdraw: _amount is 0");
        if (!isUnwind) {
            // remove the buffer from the amount
            uint256 bufferPosition = (_amount * buffer) / MAX_BPS;
            // decrement the amount by buffer position
            uint256 _remAmount = _amount - bufferPosition;
            // determine the longPosition in want
            uint256 longPositionWant = _remAmount / 2;
            // determine the short position
            uint256 shortPosition = _remAmount - longPositionWant;
            // close the short position
            int256 positionsClosed = _closePerpPosition(shortPosition);
            // determine the long position
            uint256 longPosition = uint256(positionsClosed);
            if (longPosition < IERC20(long).balanceOf(address(this))) {
                // if for whatever reason there are funds left in long when there shouldnt be then liquidate them
                if (getMarginPositions() == 0) {
                    longPosition = IERC20(long).balanceOf(address(this));
                }
                // convert the long to want
                longPositionWant = _swap(longPosition, long, want);
            } else {
                // convert the long to want
                longPositionWant = _swap(
                    IERC20(long).balanceOf(address(this)),
                    long,
                    want
                );
            }
            if (
                getAvailableMargin() >
                int256(bufferPosition + shortPosition) * DECIMAL_SHIFT
            ) {
                // withdraw the short and buffer from the margin account
                mcLiquidityPool.withdraw(
                    perpetualIndex,
                    address(this),
                    int256(bufferPosition + shortPosition) * DECIMAL_SHIFT
                );
            } else {
                mcLiquidityPool.withdraw(
                    perpetualIndex,
                    address(this),
                    getAvailableMargin()
                );
            }

            // alter position values to reflect withdrawal
            // alter buffer and shorts which may experience underflow if profits are recorded
            // on the final withdrawal before a harvest recorded the change
            positions.perpContracts = getMarginPositions();
            positions.availableMargin = getAvailableMargin();
            withdrawn = longPositionWant + shortPosition + bufferPosition;
        } else {
            withdrawn = _amount;
        }

        uint256 wantBalance = IERC20(want).balanceOf(address(this));
        // transfer the funds back to the vault, if at this point needed isnt covered then
        // record a loss
        if (_amount > wantBalance) {
            IERC20(want).safeTransfer(address(vault), wantBalance);
            loss = _amount - wantBalance;
            withdrawn = wantBalance;
        } else {
            IERC20(want).safeTransfer(address(vault), withdrawn);
            loss = 0;
        }

        emit WithdrawStrategy(withdrawn);
    }

    /**
     * @notice  emit a snapshot of the margin account
     */
    function snapshot() public {
        (
            int256 cash,
            int256 position,
            int256 availableMargin,
            int256 margin,
            int256 settleableMargin,
            bool isInitialMarginSafe,
            bool isMaintenanceMarginSafe,
            bool isMarginSafe,

        ) = mcLiquidityPool.getMarginAccount(perpetualIndex, address(this));
        emit Snapshot(
            cash,
            position,
            availableMargin,
            margin,
            settleableMargin,
            isInitialMarginSafe,
            isMaintenanceMarginSafe,
            isMarginSafe
        );
    }

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
        int256 contracts = ((int256(_amount) * DECIMAL_SHIFT) * 1e18) / price;
        // open short position
        tradeAmount = mcLiquidityPool.trade(
            perpetualIndex,
            address(this),
            -contracts,
            price - slippageTolerance,
            block.timestamp,
            referrer,
            tradeMode
        );
        emit PerpPositionOpened(tradeAmount, perpetualIndex, _amount);
    }

    /**
     * @notice  close the perpetual short position on MCDEX
     * @param   _amount the collateral to be returned from the short position
     * @return  tradeAmount the amount of perpetual contracts closed
     */
    function _closePerpPosition(uint256 _amount)
        internal
        returns (int256 tradeAmount)
    {
        // get the long asset mark price from the MCDEX oracle
        (int256 price, ) = oracle.priceTWAPLong();
        // calculate the number of contracts (*1e12 because USDC is 6 decimals)
        int256 contracts = ((int256(_amount) * DECIMAL_SHIFT) * 1e18) / price;
        if (contracts + getMarginPositions() < -dust) {
            // close short position
            tradeAmount = mcLiquidityPool.trade(
                perpetualIndex,
                address(this),
                contracts,
                price + slippageTolerance,
                block.timestamp,
                referrer,
                tradeMode
            );
        } else {
            // close all remaining short positions
            tradeAmount = mcLiquidityPool.trade(
                perpetualIndex,
                address(this),
                -getMarginPositions(),
                price + slippageTolerance,
                block.timestamp,
                referrer,
                tradeMode
            );
        }

        emit PerpPositionClosed(tradeAmount, perpetualIndex, _amount);
    }

    /**
     * @notice  close all perpetual short positions on MCDEX
     * @return  tradeAmount the amount of perpetual contracts closed
     */
    function _closeAllPerpPositions() internal returns (int256 tradeAmount) {
        // get the long asset mark price from the MCDEX oracle
        (int256 price, ) = oracle.priceTWAPLong();
        // close short position
        tradeAmount = mcLiquidityPool.trade(
            perpetualIndex,
            address(this),
            -getMarginPositions(),
            price + slippageTolerance,
            block.timestamp,
            referrer,
            tradeMode
        );
        emit AllPerpPositionsClosed(tradeAmount, perpetualIndex);
    }

    /**
     * @notice  deposit to the margin account without opening a perpetual position
     * @param   _amount the amount to deposit into the margin account
     */
    function _depositToMarginAccount(uint256 _amount) internal {
        IERC20(want).approve(address(mcLiquidityPool), _amount);
        mcLiquidityPool.deposit(
            perpetualIndex,
            address(this),
            int256(_amount) * DECIMAL_SHIFT
        );
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
        int256 newMarginCash = getAvailableMargin();
        int256 oldMarginCash = positions.availableMargin;
        if (oldMarginCash >= newMarginCash) {
            // if the margin cash held has gone down then record a loss
            loss = true;
            feeInt = oldMarginCash - newMarginCash;
        } else {
            // if the margin cash held has gone up then record a profit and withdraw the excess for redistribution
            feeInt = newMarginCash - oldMarginCash;
            mcLiquidityPool.withdraw(perpetualIndex, address(this), feeInt);
        }
        fee = IERC20(want).balanceOf(address(this));
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
     * @notice  swap function using uniswapv3 to facilitate the swap, specifying the amount in
     * @param   _amount    the amount to be swapped in want
     * @param   _tokenIn   the asset sent in
     * @param   _tokenOut  the asset taken out
     * @return  amountOut the amount of tokenOut exchanged for tokenIn
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
        address recipient = address(this);
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

    /**
     * @notice  getter for the MCDEX margin positions of the strategy
     * @return  position of the margin account
     */
    function getMarginPositions() public view returns (int256 position) {
        (, position, , , , , , , ) = mcLiquidityPool.getMarginAccount(
            perpetualIndex,
            address(this)
        );
    }

    /**
     * @notice  getter for the MCDEX margin  of the strategy
     * @return  availableMargin of the margin account
     */
    function getAvailableMargin() public view returns (int256 availableMargin) {
        (, , availableMargin, , , , , , ) = mcLiquidityPool.getMarginAccount(
            perpetualIndex,
            address(this)
        );
    }

    /**
     * @notice Get the account info of the trader. Need to update the funding state and the oracle price
     *         of each perpetual before and update the funding rate of each perpetual after
     * @return cash the cash held in the margin account
     * @return position The position of the account
     * @return availableMargin The available margin of the account
     * @return margin The margin of the account
     * @return settleableMargin The settleable margin of the account
     * @return isInitialMarginSafe True if the account is initial margin safe
     * @return isMaintenanceMarginSafe True if the account is maintenance margin safe
     * @return isMarginSafe True if the total value of margin account is beyond 0
     */
    function getMarginAccount()
        public
        view
        returns (
            int256 cash,
            int256 position,
            int256 availableMargin,
            int256 margin,
            int256 settleableMargin,
            bool isInitialMarginSafe,
            bool isMaintenanceMarginSafe,
            bool isMarginSafe // bankrupt
        )
    {
        (
            cash,
            position,
            availableMargin,
            margin,
            settleableMargin,
            isInitialMarginSafe,
            isMaintenanceMarginSafe,
            isMarginSafe,

        ) = mcLiquidityPool.getMarginAccount(perpetualIndex, address(this));
    }

    /**
     * @notice Get the funding rate
     * @return the funding rate of the perpetual
     */
    function getFundingRate() public view returns (int256) {
        (, , int256[39] memory nums) = mcLiquidityPool.getPerpetualInfo(
            perpetualIndex
        );
        return nums[3];
    }

    /**
     * @notice Get the unit accumulative funding
     * @return get the unit accumulative funding of the perpetual
     */
    function getUnitAccumulativeFunding() public view returns (int256) {
        (, , int256[39] memory nums) = mcLiquidityPool.getPerpetualInfo(
            perpetualIndex
        );
        return nums[4];
    }
}
