// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {Lasso} from "../src/Lasso.sol";
import {LassoVault} from "../src/LassoVault.sol";
import {AttestedRoad} from "../src/roads/AttestedRoad.sol";

/// @notice Portaldot side: Lasso alone (one contract keeps the storage deposit low).
/// forge script script/Deploy.s.sol:DeployPortaldot --rpc-url portaldot --broadcast
contract DeployPortaldot is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address[3] memory arbiters =
            [vm.envAddress("ARBITER0_ADDRESS"), vm.envAddress("ARBITER1_ADDRESS"), vm.envAddress("ARBITER2_ADDRESS")];

        vm.startBroadcast(key);
        // Short windows so the whole default process can be shown live: 2 min grace, 3 min to answer
        // and to vote, bond 0.01 POT.
        Lasso lasso = new Lasso(vm.addr(key), arbiters, 2 minutes, 3 minutes, 0.01 ether);
        vm.stopBroadcast();

        console.log("Lasso", address(lasso));
    }
}

/// @notice Ethereum side: the temporary road and the vault.
/// forge script script/Deploy.s.sol:DeploySepolia --rpc-url sepolia --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(key);
        AttestedRoad road = new AttestedRoad(vm.addr(key));
        LassoVault vault = new LassoVault(road);
        vm.stopBroadcast();

        console.log("AttestedRoad", address(road));
        console.log("LassoVault  ", address(vault));
    }
}
