// SPDX-FileCopyrightText: 2024 OpenZeppelin, Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.10;

import {ERC20Bridged} from "./ERC20Bridged.sol";
import {PermitExtension} from "./PermitExtension.sol";
import {Versioned} from "../utils/Versioned.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";

/// @author kovalgek, arwer13
/// @notice Non-rebasing L2 token with permit, versioning and enumerable mint/burn roles.
/// @dev Initialize metadata, signing domain and DEFAULT_ADMIN_ROLE atomically through
///      the proxy constructor. CCIP registration uses registerAccessControlDefaultAdmin;
///      the token has no separate CCIP admin hook or legacy bridge authority.
///      Role authorization and initialization incorporate the former MIT-licensed
///      BurnMintERC20BridgedPermit extension; see provenance.json for source history.
contract ERC20BridgedPermit is ERC20Bridged, PermitExtension, Versioned, AccessControlEnumerableUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @dev An initial role administrator must be nonzero.
    error ZeroAdmin();

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
    ///      The signing-domain version, Versioned storage version and OZ initializer
    ///      version have distinct meanings; deployment currently sets each to 2.
    ///      After this call, the legacy initialization entrypoints also revert.
    /// @param name_ The name of the token
    /// @param symbol_ The symbol of the token
    /// @param version_ The major version of the EIP-712 signing domain
    /// @param admin_ The initial DEFAULT_ADMIN_ROLE holder
    function initialize(string memory name_, string memory symbol_, string memory version_, address admin_)
        external
        reinitializer(2)
    {
        if (admin_ == address(0)) revert ZeroAdmin();
        _initializeERC20Metadata(name_, symbol_);
        _initialize_v2(name_, version_);
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
