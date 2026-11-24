// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @dev Test double of lido-l2 `OssifiableProxy` (082e7eb, OpenZeppelin 4.6.0), the proxy in front
///     of the fleet token, rebuilt on OpenZeppelin 5.0.2 `ERC1967Proxy`. Same observable semantics
///     for what the tests rely on: EIP-1967 implementation and admin slots, `proxy__*` entrypoints
///     gated by the admin, `proxy__upgradeToAndCall` delegating the setup call with `msg.sender`
///     still the admin, and no transparent-proxy admin blocking (the admin can call the
///     implementation). Not deployable; the live proxies keep their original bytecode.
contract OssifiableProxyDouble is ERC1967Proxy {
    constructor(address implementation_, address admin_, bytes memory data_) ERC1967Proxy(implementation_, data_) {
        ERC1967Utils.changeAdmin(admin_);
    }

    function proxy__getAdmin() external view returns (address) {
        return ERC1967Utils.getAdmin();
    }

    function proxy__getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    function proxy__upgradeTo(address newImplementation_) external onlyAdmin {
        ERC1967Utils.upgradeToAndCall(newImplementation_, "");
    }

    function proxy__upgradeToAndCall(address newImplementation_, bytes memory setupCalldata_, bool forceCall_)
        external
        onlyAdmin
    {
        if (setupCalldata_.length == 0 && !forceCall_) {
            ERC1967Utils.upgradeToAndCall(newImplementation_, "");
        } else if (setupCalldata_.length == 0) {
            ERC1967Utils.upgradeToAndCall(newImplementation_, "");
            Address.functionDelegateCall(newImplementation_, "");
        } else {
            ERC1967Utils.upgradeToAndCall(newImplementation_, setupCalldata_);
        }
    }

    /// @dev Upstream (OpenZeppelin 4.6 `Proxy`) accepts plain ether; keeps the double faithful.
    receive() external payable {}

    modifier onlyAdmin() {
        address admin = ERC1967Utils.getAdmin();
        if (admin == address(0)) {
            revert ErrorProxyIsOssified();
        }
        if (admin != msg.sender) {
            revert ErrorNotAdmin();
        }
        _;
    }

    error ErrorNotAdmin();
    error ErrorProxyIsOssified();
}
