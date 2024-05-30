// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title DecentralizedStableCoin
/// @author ge1u
/// 抵押品类型：外部
/// 发行（稳定性机制）：去中心化（算法驱动）
/// 价值（相对稳定性）：锚定（与美元挂钩）
/// 这个合约设计为由DSCEngine拥有。
/// 可以由DSCEngine智能进行铸造和销毁。
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    /*//////////////////////////////////////////////////////////////////////////
                                errors
    //////////////////////////////////////////////////////////////////////////*/
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    /*//////////////////////////////////////////////////////////////////////////
                                constructor
    //////////////////////////////////////////////////////////////////////////*/
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////////////////
                                public
    //////////////////////////////////////////////////////////////////////////*/
    function burn(uint256 _amount) public override onlyOwner {
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        uint256 balance = balanceOf(msg.sender);
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
