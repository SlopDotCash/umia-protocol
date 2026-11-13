// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

contract MockArbSys {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal _arbBlockNumber;

    function setArbBlockNumber(uint256 value) external {
        _arbBlockNumber = value;
        // Foundry handles arbBlockNumber() at 0x64 natively even when code is etched there.
        // Override that selector so the fixture's L2 height stays independent of vm.roll.
        VM.mockCall(address(this), abi.encodeWithSelector(this.arbBlockNumber.selector), abi.encode(value));
    }

    function arbBlockNumber() external view returns (uint256) {
        return _arbBlockNumber;
    }
}
