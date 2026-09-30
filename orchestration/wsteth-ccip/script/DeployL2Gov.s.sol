// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IDeployedOpExec {
    function OVM_L2_CROSS_DOMAIN_MESSENGER() external view returns (address);
    function getEthereumGovernanceExecutor() external view returns (address);
    function getDelay() external view returns (uint256);
    function getGracePeriod() external view returns (uint256);
    function getMinimumDelay() external view returns (uint256);
    function getMaximumDelay() external view returns (uint256);
    function getGuardian() external view returns (address);
}

/// @notice Step 02 — deploy the L2 governance executor on the OP-stack L2 (default Mantle Sepolia).
/// `ethereumGovernanceExecutor` is pinned to the L1 Aragon Agent (the on-chain sender of
/// L1CrossDomainMessenger.sendMessage, even behind Dual Governance).
contract DeployL2Gov is Script {
    // OP-stack L2CrossDomainMessenger predeploy (same on every OP chain).
    address internal constant L2_MESSENGER = 0x4200000000000000000000000000000000000007;

    function run() external {
        address agent = vm.envAddress("L1_AGENT");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Disposable-testnet defaults: immediate execution, 1-day grace, 0..1-day bounds. All are
        // env-overridable so this script is not silently reused with a zero timelock on a
        // non-throwaway deployment. The guardian defaults to the deployer (rather than address(0))
        // so cancel() remains usable as an emergency brake — guardian == address(0) would make the
        // onlyGuardian check permanently unsatisfiable.
        uint256 delay = vm.envOr("OPEXEC_DELAY", uint256(0));
        uint256 gracePeriod = vm.envOr("OPEXEC_GRACE_PERIOD", uint256(1 days));
        uint256 minimumDelay = vm.envOr("OPEXEC_MIN_DELAY", uint256(0));
        uint256 maximumDelay = vm.envOr("OPEXEC_MAX_DELAY", uint256(1 days));
        address guardian = vm.envOr("OPEXEC_GUARDIAN", deployer);

        vm.startBroadcast(pk);
        // Compile the upstream 0.8.10 contract separately; CREATE still broadcasts from the deployer.
        address opExec = deployCode(
            "out-token/OptimismBridgeExecutor.sol/OptimismBridgeExecutor.json",
            abi.encode(L2_MESSENGER, agent, delay, gracePeriod, minimumDelay, maximumDelay, guardian)
        );
        vm.stopBroadcast();
        IDeployedOpExec deployed = IDeployedOpExec(opExec);
        require(deployed.OVM_L2_CROSS_DOMAIN_MESSENGER() == L2_MESSENGER, "OpExec messenger mismatch");
        require(deployed.getEthereumGovernanceExecutor() == agent, "OpExec L1 agent mismatch");
        require(deployed.getDelay() == delay, "OpExec delay mismatch");
        require(deployed.getGracePeriod() == gracePeriod, "OpExec grace period mismatch");
        require(deployed.getMinimumDelay() == minimumDelay, "OpExec minimum delay mismatch");
        require(deployed.getMaximumDelay() == maximumDelay, "OpExec maximum delay mismatch");
        require(deployed.getGuardian() == guardian, "OpExec guardian mismatch");

        console.log("OptimismBridgeExecutor:", address(opExec));
        console.log("ethereumGovernanceExecutor (L1 Agent):", agent);
        vm.writeFile(vm.envString("OPEXEC_OUT"), vm.toString(address(opExec)));
    }
}
