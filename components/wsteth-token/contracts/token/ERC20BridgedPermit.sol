// SPDX-FileCopyrightText: 2024 OpenZeppelin, Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {ERC20Bridged} from "./ERC20Bridged.sol";
import {PermitExtension} from "./PermitExtension.sol";
import {Versioned} from "../utils/Versioned.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @author kovalgek, arwer13
/// @notice Non-rebasing L2 token with permit, contract versioning and enumerable mint and burn
///         roles.
/// @dev A new proxy sets name, symbol, signing domain and DEFAULT_ADMIN_ROLE in one call,
///      `initialize`, passed as the proxy constructor's init data; a proxy running an earlier
///      implementation is upgraded with `finalizeUpgrade_v3`. Minting and burning are authorized
///      only by MINTER_ROLE and BURNER_ROLE; no bridge address has authority of its own. The CCIP
///      token admin registry recognizes the DEFAULT_ADMIN_ROLE holder as the token administrator
///      (`RegistryModuleOwnerCustom.registerAccessControlDefaultAdmin`).
contract ERC20BridgedPermit is ERC20Bridged, PermitExtension, Versioned, AccessControlEnumerableUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @dev An initial role administrator must be nonzero.
    error ZeroAdmin();

    /// @dev `finalizeUpgrade_v3` was called by an account other than the proxy admin.
    error ErrorNotProxyAdmin();

    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    /// @param version_ The current major version of the signing domain (aka token version)
    /// @param decimals_ The decimals places of the token
    constructor(
        string memory name_,
        string memory symbol_,
        string memory version_,
        uint8 decimals_
    )
        ERC20Bridged(name_, symbol_, decimals_)
        PermitExtension(name_, version_)
    {
        // Lock OZ initialization on the implementation. Versioned independently
        // petrifies the implementation's storage version in its constructor.
        _disableInitializers();
    }

    /// @notice Initializes a new proxy, including its role administrator.
    /// @dev Supply this call as the proxy constructor's initData. Deploying an
    ///      uninitialized proxy allows another caller to initialize it first.
    ///      Reverts if a name and symbol are already stored. That is the state of an existing
    ///      proxy upgraded to this implementation before `finalizeUpgrade_v3` has run: its
    ///      OpenZeppelin (OZ) initializer version is still zero, and without this check anyone
    ///      could seat the administrator through this function.
    ///      Three versions appear here and are distinct values: `version_` is the EIP-712 domain
    ///      version string, the stored Lido contract version is 3 (the same this implementation
    ///      gives an upgraded fleet proxy in `finalizeUpgrade_v3`, so one code base reports one
    ///      version and a future `finalizeUpgrade_v4` has one starting point), and
    ///      `reinitializer(2)` is the OZ initializer version. After this call the three-argument
    ///      `initialize` and `finalizeUpgrade_v2` revert too, because the metadata is stored.
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    /// @param version_ The major version of the EIP-712 signing domain
    /// @param admin_ The initial DEFAULT_ADMIN_ROLE holder
    function initialize(string memory name_, string memory symbol_, string memory version_, address admin_)
        external
        reinitializer(2)
    {
        if (admin_ == address(0)) revert ZeroAdmin();
        if (_isMetadataInitialized()) revert ErrorMetadataIsAlreadyInitialized();
        _initializeERC20Metadata(name_, symbol_);
        _initializeContractVersionTo(3);
        _initializeEIP5267Metadata(name_, version_);
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @dev Mints tokens to an account. The caller must have the MINTER_ROLE.
    /// @param account_ The address of the account to mint tokens to
    /// @param amount_ The amount of tokens to mint
    function mint(address account_, uint256 amount_) external onlyRole(MINTER_ROLE) {
        _mint(account_, amount_);
    }

    /// @dev Burns tokens from the caller. The caller must have the BURNER_ROLE.
    /// @param amount_ The amount of tokens to burn
    function burn(uint256 amount_) external onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount_);
    }

    /// @dev Burns `amount_` from `account_` and spends the caller's allowance by that amount. The
    ///      caller must have the BURNER_ROLE. The Lido L2 bridge withdraws through this function,
    ///      so a withdrawal through the bridge needs an allowance to the bridge; the CCIP token
    ///      pool burns through `burn(uint256)`.
    /// @param account_ The address of the account to burn tokens from
    /// @param amount_ The amount of tokens to burn
    function burnFrom(address account_, uint256 amount_) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account_, msg.sender, amount_);
        _burn(account_, amount_);
    }

    /// @notice Upgrade entrypoint for an existing proxy whose previous implementation was
    ///         `ERC20Bridged` from lidofinance/lido-l2 (contract version 0, no EIP-712 metadata).
    ///         The version-2 branch is accepted but has not been qualified against the
    ///         lido-l2-with-steth implementation deployed on Optimism.
    /// @dev Keeps the stored name, symbol, balances and allowances. Stores the EIP-5267 name and
    ///      version from the stored name and `version_`; both must equal the values this
    ///      implementation was constructed with, otherwise `ErrorEIP712DomainMismatch`. Sets the
    ///      contract version to 3, from 0 or 2 only. Seats the role administrator.
    ///      Only the proxy admin read from the EIP-1967 admin slot may call it: for
    ///      `OssifiableProxy` that is the admin calling `proxy__upgradeToAndCall`, for a
    ///      transparent proxy the `ProxyAdmin` calling `upgradeAndCall`. The upgrade should be
    ///      atomic with this call: in between, the token has no administrator and the L2 bridge
    ///      no mint or burn role, although nobody else can seat the administrator because
    ///      `initialize` refuses stored metadata. Runs once; afterwards both this function and
    ///      `initialize` revert on the same OZ initializer version.
    /// @param version_ The major version of the EIP-712 signing domain
    /// @param admin_ The initial DEFAULT_ADMIN_ROLE holder
    function finalizeUpgrade_v3(string memory version_, address admin_) external reinitializer(2) {
        if (msg.sender != ERC1967Utils.getAdmin()) revert ErrorNotProxyAdmin();
        if (admin_ == address(0)) revert ZeroAdmin();
        if (!_isMetadataInitialized()) revert ErrorMetadataIsNotInitialized();
        _initializeEIP5267Metadata(name(), version_);
        if (getContractVersion() == 0) {
            _initializeContractVersionTo(3);
        } else {
            _updateContractVersion(3);
        }
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Legacy metadata initialization entrypoint, retained for ABI compatibility.
    /// @dev Does not initialize roles. New proxies must use the four-argument initializer.
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    /// @param version_ The version of the token
    function initialize(string memory name_, string memory symbol_, string memory version_) external {
        if (_isMetadataInitialized()) {
            revert ErrorMetadataIsAlreadyInitialized();
        }
        _initializeERC20Metadata(name_, symbol_);
        _initialize_v2(name_, version_);
    }

    /// @notice A function to finalize upgrade to v2 (from v1).
    function finalizeUpgrade_v2(string memory name_, string memory version_) external {
        if (!_isMetadataInitialized()) {
            revert ErrorMetadataIsNotInitialized();
        }
        _initialize_v2(name_, version_);
    }

    function _initialize_v2(string memory name_, string memory version_) internal {
        _initializeContractVersionTo(2);
        _initializeEIP5267Metadata(name_, version_);
    }

    /// @inheritdoc PermitExtension
    function _permitAccepted(address owner_, address spender_, uint256 amount_) internal override {
        _approve(owner_, spender_, amount_);
    }

    error ErrorMetadataIsNotInitialized();
    error ErrorMetadataIsAlreadyInitialized();
}
