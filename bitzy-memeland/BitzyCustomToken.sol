// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IBitzyCustomToken.sol";

contract BitzyCustomToken is ERC20, Ownable, IBitzyCustomToken {
    uint8 private _customDecimals;
    address private _admin;
    bool public _migrated;
    address private _pool;

    constructor(
        string memory name, 
        string memory symbol, 
        uint8 decimals_
    ) ERC20(name, symbol) {
        _customDecimals = decimals_;
        _admin = msg.sender;
        _migrated = false;
        transferOwnership(msg.sender);
    }

    function decimals() public view virtual override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function migrated() external override {
        require( msg.sender == _admin, "Only admin!");
        _migrated = true;
    }

    function setBlacklist(address pool_) external override {
        require( msg.sender == _admin, "Only admin!");
        _pool = pool_;
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        if(!_migrated){
            require( recipient != _pool, "Recipient cant be pool!");  
        }
        return super.transfer(recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        if(!_migrated){
            require( recipient != _pool, "Recipient cant be pool!");  
        }
        return super.transferFrom(sender, recipient, amount);
    }
}
