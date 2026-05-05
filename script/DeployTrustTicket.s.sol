// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {TrustTicket} from "../contracts/TrustTicket.sol";

contract DeployTrustTicket is Script {
    function run() external returns (TrustTicket trustTicket) {
        address admin = vm.envOr("TRUST_TICKET_ADMIN", msg.sender);

        vm.startBroadcast();
        trustTicket = new TrustTicket(admin);
        vm.stopBroadcast();
    }
}
