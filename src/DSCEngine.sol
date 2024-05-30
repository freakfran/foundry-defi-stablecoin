// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title DSCEngine
/// @author ge1u
/// 系统设计尽可能简洁，目标是使代币始终维持1个代币等于$1的汇率。
/// 这是一个具有以下属性的稳定币：
/// 外部抵押
/// 美元挂钩
/// 通过算法实现稳定
/// @notice 此合约是去中心化稳定币系统的核心。它处理DSC的铸造、赎回以及抵押品的存入和提取的所有逻辑。
//          此合约基于MakerDAO的DSS系统构建
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////////////////
                                  errors
    //////////////////////////////////////////////////////////////////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////////////////
                                  State variables
    //////////////////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; //ETH/USD的精度8，所以乘以1e10，得到18位精度
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; //10%
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    DecentralizedStableCoin private immutable i_dsc;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    /*//////////////////////////////////////////////////////////////////////////
                                  Events
    //////////////////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                  Modifiers
    //////////////////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  constructor
    //////////////////////////////////////////////////////////////////////////*/
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  external
    //////////////////////////////////////////////////////////////////////////*/

    /// 调用此函数将存入抵押品并铸造DSC代币
    /// @param collateralTokenAddress 抵押品代币的地址
    /// @param amountCollateral 要存入的抵押品数量
    /// @param amountDscToMint 要铸造的DSC代币数量
    /// @dev 首先调用`depositCollateral`函数存入抵押品，然后调用`mintDsc`函数铸造DSC代币
    function depositCollateralAndMintDsc(
        address collateralTokenAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(collateralTokenAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /// 调用此函数将销毁DSC并赎回相应的抵押品
    /// @dev 此函数先调用内部的burnDsc函数来销毁DSC，然后调用redeemCollateral来赎回抵押品
    /// @param collateralTokenAddress 抵押品代币的地址
    /// @param amountCollateralToRedeem 要赎回的抵押品数量
    /// @param amountDscToBurn 要销毁的DSC数量
    function redeemCollateralForDsc(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralTokenAddress, amountCollateralToRedeem);
    }

    /* 清算用户
     * @param collateralTokenAddress: 要用来使协议恢复偿付能力的ERC20抵押品代币地址。
     *                                这是你将从破产用户那里取回的抵押品。
     *                                作为回报，你需要用你的DSC来偿还他们的债务，但你不需要偿还自己的债务。
     * @param user: 破产的用户。他们的_healthFactor必须低于MIN_HEALTH_FACTOR。
     * @param debtToCoverInUsd: 你想销毁的DSC数量，以覆盖用户的债务。
     * @dev:可以部分清算一个用户。
     *      你将获得用户资金的10%清算奖励。
     *      此功能的正常工作假设协议将大约有150%的超额抵押，以便此操作能生效。
     *      已知的漏洞是如果协议只有100%的抵押，我们将无法清算任何人。
     */
    function liquidate(address collateralTokenAddress, address user, uint256 debtToCoverInUsd)
        external
        moreThanZero(debtToCoverInUsd)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralTokenAddress, debtToCoverInUsd);
        // 10% bonus
        uint256 liquidationBonus = tokenAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + liquidationBonus;
        _redeemCollateral(collateralTokenAddress, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCoverInUsd, user, msg.sender);
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                public
    //////////////////////////////////////////////////////////////////////////*/
    /// 存款抵押品
    /// @dev 该函数允许用户向系统存入指定数量的抵押品代币，以支持稳定币的发行和维护抵押率。
    /// @param collateralTokenAddress 抵押品代币的地址。
    /// @param amountCollateral 要存入的抵押品代币的数量。以该代币的最小单位表示
    function depositCollateral(address collateralTokenAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, amountCollateral);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /// 铸造DSC代币
    /// @dev 铸币者必须有比最低阈值高的抵押品
    /// @param amountDscToMint 需要铸造的DSC代币数量。
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /// 销毁DSC代币
    /// @param amountDscToBurn 需要销毁的DSC代币数量。
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // 大概率不会发生
    }

    /// 赎回抵押品
    /// @param collateralTokenAddress 需要赎回的token地址
    /// @param amountCollateral 要赎回的token数量
    function redeemCollateral(address collateralTokenAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(collateralTokenAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        internal&private view&pure functions
    //////////////////////////////////////////////////////////////////////////*/

    /// 赎回抵押品
    /// @param collateralTokenAddress 需要赎回的token地址
    /// @param amountCollateral 要赎回的token数量
    /// @param from 从谁那里赎回
    /// @param to 赎回给谁
    function _redeemCollateral(address collateralTokenAddress, uint256 amountCollateral, address from, address to)
        private
    {
        //100-1000 不满足uint solidity 会回滚
        s_collateralDeposited[from][collateralTokenAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, collateralTokenAddress, amountCollateral);
        bool success = IERC20(collateralTokenAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /// 销毁DSC代币
    /// @param amountDscToBurn 需要销毁的DSC代币数量。
    /// @param onBehalfOf 销毁的是谁的dsc
    /// @param amountDscToBurn 发送者
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        public
        moreThanZero(amountDscToBurn)
    {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /// 用户信息（dsc和质押品美元价值）
    /// @param user 用户地址
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /// 健康因子
    /// @dev 用户距离被清算的距离，如果低于1e18，将被清算
    /// @param 用户地址
    function _healthFactor(address user) private view returns (uint256) {
        // 100DSC , 200USD value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        // (200*50) / 100 = 100
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // 100 * 1e18 / 100 = 1e18
        return collateralAdjustedForThreshold * PRECISION / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 healthFactor = _healthFactor(_user);
        if (healthFactor < 1) {
            revert DSCEngine__HealthFactorIsBroken(healthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    external&public view&pure functions
    //////////////////////////////////////////////////////////////////////////*/
    /// 用户质押品的美元价值
    /// @dev 获取用户每种质押品的美元价值，并将其相加返回
    /// @param user 用户地址
    function getAccountCollateralValueInUsd(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /// token的美元价值
    /// @param token token地址
    /// @param amount token数量
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //1eth = 1000usd
        //amount = 1
        //1000e8 * 1e10 * 1 / 1e18 = 1000
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / 1e18;
    }

    /// usd能换多少token
    /// @param token token地址
    /// @param usdAmountInWei usd数量
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //1ETH => 1000USD
        //1e18 * 1e18 / 1000e8 * 1e10 = 1e18 / 1000 = 1e15
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
