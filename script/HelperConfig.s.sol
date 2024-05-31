// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "lib/forge-std/src/Script.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMAL_USD = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    NetConfig public activeNetworkConfig;
    address USER = makeAddr("user");

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetConfig memory) {
        NetConfig memory sepoliaConfig = NetConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY")
        });
        return sepoliaConfig;
    }

    function getOrCreateAnvilEthConfig() public returns (NetConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }
        vm.startBroadcast();
        MockV3Aggregator wethUsdPriceFeedMock = new MockV3Aggregator(DECIMAL_USD, ETH_USD_PRICE);
        ERC20Mock wethMock = new ERC20Mock();
        wethMock.mint(USER, 1000e18);
        MockV3Aggregator wbtcUsdPriceFeedMock = new MockV3Aggregator(DECIMAL_USD, BTC_USD_PRICE);
        ERC20Mock wbtcMock = new ERC20Mock();
        wbtcMock.mint(USER, 1000e18);
        vm.stopBroadcast();

        NetConfig memory anvilConfig = NetConfig({
            wethUsdPriceFeed: address(wethUsdPriceFeedMock),
            wbtcUsdPriceFeed: address(wbtcUsdPriceFeedMock),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: vm.envUint("ANVIL_PRIVATE_KEY")
        });
        return anvilConfig;
    }
}
