//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";


interface AaveProtocolDataProvider {

    function getUserReserveData(address asset, address user)
    external
    view
    returns (
      uint256 currentATokenBalance,
      uint256 currentStableDebt,
      uint256 currentVariableDebt,
      uint256 principalStableDebt,
      uint256 scaledVariableDebt,
      uint256 stableBorrowRate,
      uint256 liquidityRate,
      uint40 stableRateLastUpdated,
      bool usageAsCollateralEnabled
    );
}


interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    ILendingPool public aaveLendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    address public debtAsset = 0xdAC17F958D2ee523a2206206994597C13D831ec7;  // USDT
    address public collateralAsset = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // WBTC
    IUniswapV2Pair public uniswapPair_WBTC =IUniswapV2Pair(0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58) ; // sushiswap RESERVE0: WBTC reserve1 :WETH
    IUniswapV2Pair public uniswapPair_USDT = IUniswapV2Pair(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852) ; // uniswap RESERVE0: WETH reserve1 :USDT
    
    IWETH public WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    AaveProtocolDataProvider public aaveProtocolDataProvider = AaveProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);


    constructor() payable {
    }


    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }


    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }


    function operate() external {

        address user = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
        (, , , , , uint256 healthFactor) = aaveLendingPool.getUserAccountData(user);
        require(healthFactor < 10**health_factor_decimals, "Target is not liquidatable"); // Health factor below 1 means liquidatable



        // (,uint256 currentStableDebt,uint256 currentVariableDebt,,,,,,) = aaveProtocolDataProvider.getUserReserveData(debtAsset,user);
        // uint amount = (currentStableDebt + currentVariableDebt) /10 ; 
        uint amount = 2401970077573;

        bytes memory data = abi.encode(msg.sender,user, amount);
        uniswapPair_USDT.swap(0, amount, address(this), data);

    }

    receive() external payable {
    }


    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {



        require(msg.sender == address(uniswapPair_USDT), "Only uniswapPair can invoke");
        require(sender == address(this), "Only this contract may initiate");

        (address initiator, address user, uint256 amount) = abi.decode(data, (address, address, uint256));
        IERC20(debtAsset).approve(address(aaveLendingPool), amount);


        aaveLendingPool.liquidationCall(collateralAsset, debtAsset, user, amount, false);
        uint256 collateralAmount = IERC20(collateralAsset).balanceOf(address(this));

    

        IERC20(collateralAsset).transfer(address(uniswapPair_WBTC), collateralAmount); //WBTC to WETH

        (uint256 uniswapPair_WBTC_reserve0,uint256 uniswapPair_WBTC_reserve1,) = uniswapPair_WBTC.getReserves();// WBTC to WETH
        (uint256 uniswapPair_USDT_reserve0,uint256 uniswapPair_USDT_reserve1,) = uniswapPair_USDT.getReserves(); // WETH to USDT


        uint256 amount_ETH_In = getAmountOut(collateralAmount, uniswapPair_WBTC_reserve0, uniswapPair_WBTC_reserve1); //In my account

        uint256 amount_ETH_Out = getAmountIn(amount, uniswapPair_USDT_reserve0, uniswapPair_USDT_reserve1);// In the flash loan pool

        uniswapPair_WBTC.swap(0, amount_ETH_In, address(this), "");

        WETH.transfer(address(uniswapPair_USDT), amount_ETH_Out);



        uint256 remainingCollateral = IERC20(collateralAsset).balanceOf(address(this));
        WETH.withdraw(WETH.balanceOf(address(this)));
        payable(initiator).transfer(address(this).balance); // Send profits back to the initiator
    }

}
