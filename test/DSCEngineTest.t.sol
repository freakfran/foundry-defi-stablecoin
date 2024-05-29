// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelpConfig} from "script/HelpConfig.s.sol";
import {MockERC20} from "lib/forge-std/src/mocks/MockERC20.sol";

contract DSCEngineTest is Test {
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelpConfig public config;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;
    address USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();
        (dsc, engine, config) = deployDSC.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        vm.deal(USER, 100 ether);
    }

    function testGetUsdValue() public view {
        uint256 wethValue = engine.getUsdValue(weth, 1 ether);
        assert(wethValue == 2000e18);
        uint256 wbtcValue = engine.getUsdValue(wbtc, 1 ether);
        assert(wbtcValue == 1000e18);
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        MockERC20(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
