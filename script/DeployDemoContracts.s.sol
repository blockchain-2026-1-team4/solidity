// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FanClubMembership} from "../contracts/FanClubMembership.sol";
import {TrustTicket} from "../contracts/TrustTicket.sol";

contract DeployDemoContracts is Script {
    function run() external returns (TrustTicket trustTicket, FanClubMembership fanClubMembership) {
        address admin = vm.envOr("TRUST_TICKET_ADMIN", msg.sender);

        vm.startBroadcast();
        fanClubMembership = new FanClubMembership(admin);
        trustTicket = new TrustTicket(admin);
        vm.stopBroadcast();
    }
}
