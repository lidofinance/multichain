// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IDeployedL2Token {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function getContractVersion() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

/// @notice Step 03 — deploy the L2 wstETH (ERC20BridgedPermit) behind an OssifiableProxy.
/// Greenfield init: proxy initData = initialize(name, symbol, version, deployer), which atomically
/// sets the metadata, the EIP-712/5267 domain, the contract version AND seats DEFAULT_ADMIN_ROLE in
/// the same tx (no front-run window). Proxy admin + token admin stay with the deployer until step 07
/// hands both to the OptimismBridgeExecutor; the CCIP pool gets MINTER_ROLE/BURNER_ROLE in step 07 A.
contract DeployL2Token is Script {
    string internal constant NAME = "Wrapped liquid staked Ether 2.0";
    string internal constant SYMBOL = "wstETH";
    uint8 internal constant DECIMALS = 18;
    /// @dev EIP-712 signing-domain version. Enters every `permit` signature this token will ever
    /// accept, so it is fixed here rather than passed in: changing it invalidates outstanding
    /// signatures. "2" matches the deployed Lido fleet (wstETH on OP Mainnet) and the contract
    /// version `initialize` sets — upstream's rule is that the two agree.
    string internal constant VERSION = "2";

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        // The local wsteth-token base has no legacy bridge authority; mint/burn
        // permissions are exclusively revocable MINTER_ROLE/BURNER_ROLE grants.
        address impl = deployCode(
            "out-token/ERC20BridgedPermit.sol/ERC20BridgedPermit.json",
            abi.encode(NAME, SYMBOL, VERSION, DECIMALS)
        );
        // initData seats metadata + EIP-712 domain + contract version + DEFAULT_ADMIN_ROLE
        // atomically inside the proxy constructor, so there is no window in which the proxy is live
        // without an admin, and no window in which anyone else can fix the permit domain.
        address proxy = deployCode(
            "out-token/OssifiableProxy.sol/OssifiableProxy.json",
            abi.encode(
                impl,
                deployer,
                abi.encodeWithSignature("initialize(string,string,string,address)", NAME, SYMBOL, VERSION, deployer)
            )
        );
        vm.stopBroadcast();
        IDeployedL2Token deployed = IDeployedL2Token(proxy);
        require(deployed.proxy__getImplementation() == impl, "Token implementation mismatch");
        require(deployed.proxy__getAdmin() == deployer, "Token proxy admin mismatch");
        require(keccak256(bytes(deployed.name())) == keccak256(bytes(NAME)), "Token name mismatch");
        require(keccak256(bytes(deployed.symbol())) == keccak256(bytes(SYMBOL)), "Token symbol mismatch");
        require(deployed.decimals() == DECIMALS, "Token decimals mismatch");
        require(deployed.getContractVersion() == 2, "Token version mismatch");
        require(deployed.hasRole(bytes32(0), deployer), "Token admin mismatch");

        console.log("L2 wstETH proxy:", address(proxy));
        console.log("L2 wstETH impl :", address(impl));
        // The deployer EOA now holds BOTH the proxy-upgrade right and the token DEFAULT_ADMIN_ROLE
        // (and thus grantRole(MINTER_ROLE, ...)). This is a single-key window with no timelock: it
        // MUST be closed by step 07 (hand both to the OptimismBridgeExecutor) before any live
        // traffic / before the CCIP pool is granted MINTER_ROLE in step 07 goes to production.
        console.log(
            "WARNING: deployer holds proxy-admin + token DEFAULT_ADMIN_ROLE; run step 07 (handover to OpExec) before going live."
        );
        console.log("deployer (must hand over):", deployer);
        vm.writeFile(vm.envString("TOKEN_OUT"), string.concat(vm.toString(proxy), " ", vm.toString(impl)));
    }
}
