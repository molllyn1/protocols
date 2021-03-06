// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.6.10;


/// @title PriceOracle
interface PriceOracle
{
    // @dev Return's the token's value in ETH
    function tokenValue(address token, uint amount)
        external
        view
        returns (uint value);
}