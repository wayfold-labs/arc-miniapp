// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {PayLink} from "../src/PayLink.sol";

contract Deploy is Script {
    address private constant USDC = 0x3600000000000000000000000000000000000000;
    address private constant MAINNET_EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address private constant TESTNET_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    error UnsupportedChain(uint256 chainId);

    function run() external returns (PayLink deployed) {
        address eurc;
        if (block.chainid == 5042) {
            eurc = MAINNET_EURC;
        } else if (block.chainid == 5042002) {
            eurc = TESTNET_EURC;
        } else {
            revert UnsupportedChain(block.chainid);
        }

        vm.startBroadcast();
        deployed = new PayLink(USDC, eurc);
        vm.stopBroadcast();
    }
}
