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
}

interface IProxyAdmin {
    function owner() external view returns (address);
}

/// @notice Step 03 — deploy the L2 wstETH (ERC20BridgedPermit) behind an OpenZeppelin 5.3.0
/// TransparentUpgradeableProxy, the proxy the CCIP scripts deploy BurnMintERC20Transparent behind.
/// Greenfield init: proxy initData = initialize(name, symbol, version, deployer), which atomically
/// sets the metadata, the EIP-712/5267 domain, the contract version AND seats DEFAULT_ADMIN_ROLE in
/// the same tx (no front-run window). The proxy constructor also creates the ProxyAdmin and makes
/// L2_OPEXEC (the OptimismBridgeExecutor from step 02) its owner, so the upgrade right never sits
/// with the deployer. Only the token DEFAULT_ADMIN_ROLE stays with the deployer until step 07 hands
/// it to the OptimismBridgeExecutor; the CCIP pool gets MINTER_ROLE/BURNER_ROLE in step 07 A.
contract DeployL2Token is Script {
    string internal constant NAME = "Wrapped liquid staked Ether 2.0";
    string internal constant SYMBOL = "wstETH";
    uint8 internal constant DECIMALS = 18;
    /// @dev EIP-712 signing-domain version. Enters every `permit` signature this token will ever
    /// accept, so it is fixed here rather than passed in: changing it invalidates outstanding
    /// signatures. "2" matches the deployed Lido fleet (wstETH on OP Mainnet) and the contract
    /// version `initialize` sets — upstream's rule is that the two agree.
    string internal constant VERSION = "2";

    // EIP-1967 slots. ERC1967Utils of the 5.3.0 proxy edition; constants rather than an import so
    // this script keeps compiling under the default profile (CCIP's OZ 5.3.0 shares them anyway).
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Owner of the ProxyAdmin from the first block: the L2 governance executor (step 02).
        address opExec = vm.envAddress("L2_OPEXEC");
        require(opExec != address(0), "L2_OPEXEC must be the OptimismBridgeExecutor address");
        require(opExec.code.length > 0, "L2_OPEXEC has no code on this chain");

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
        // TransparentUpgradeableProxy(logic, initialOwner, data): initialOwner owns the ProxyAdmin
        // the constructor creates and writes into the EIP-1967 admin slot. The artifact comes from
        // the components/wsteth-token build (OZ 5.3.0 is a submodule inside that root, so the metadata
        // names `lib/openzeppelin-contracts-5.3.0/contracts/...` sources and not this machine's
        // checkout path); step 03 builds it.
        address proxy = deployCode(
            "../../components/wsteth-token/out/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json",
            abi.encode(
                impl,
                opExec,
                abi.encodeWithSignature("initialize(string,string,string,address)", NAME, SYMBOL, VERSION, deployer)
            )
        );
        vm.stopBroadcast();

        address proxyAdmin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        require(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))) == impl, "Token implementation mismatch");
        require(proxyAdmin.code.length > 0, "Token ProxyAdmin missing");
        require(IProxyAdmin(proxyAdmin).owner() == opExec, "Token ProxyAdmin owner mismatch");
        IDeployedL2Token deployed = IDeployedL2Token(proxy);
        require(keccak256(bytes(deployed.name())) == keccak256(bytes(NAME)), "Token name mismatch");
        require(keccak256(bytes(deployed.symbol())) == keccak256(bytes(SYMBOL)), "Token symbol mismatch");
        require(deployed.decimals() == DECIMALS, "Token decimals mismatch");
        require(deployed.getContractVersion() == 2, "Token version mismatch");
        require(deployed.hasRole(bytes32(0), deployer), "Token admin mismatch");

        console.log("L2 wstETH proxy      :", proxy);
        console.log("L2 wstETH impl       :", impl);
        console.log("L2 wstETH ProxyAdmin :", proxyAdmin, "(owner: OpExec)");
        // The deployer EOA holds the token DEFAULT_ADMIN_ROLE (and thus grantRole(MINTER_ROLE, ...))
        // until step 07 hands it to the OptimismBridgeExecutor. The proxy-upgrade right is already
        // with OpExec through the ProxyAdmin. Close the remaining single-key window with step 07
        // before any live traffic / before the CCIP pool's MINTER_ROLE goes to production.
        console.log(
            "WARNING: deployer holds token DEFAULT_ADMIN_ROLE; run step 07 (handover to OpExec) before going live."
        );
        console.log("deployer (must hand over):", deployer);
        vm.writeFile(
            vm.envString("TOKEN_OUT"),
            string.concat(vm.toString(proxy), " ", vm.toString(impl), " ", vm.toString(proxyAdmin))
        );
    }
}
