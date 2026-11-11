// SPDX-FileCopyrightText: 2024 OpenZeppelin, Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IERC2612} from "@openzeppelin/contracts/interfaces/IERC2612.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {UnstructuredRefStorage} from "../lib//UnstructuredRefStorage.sol";

/// @author arwer13, kovalgek
/// @dev The EIP-712 domain is derived from constructor immutables, as in the OpenZeppelin 4.x
///      `EIP712` base this contract previously inherited. OpenZeppelin 5.x `EIP712` adds two
///      storage strings; they are deliberately not inherited so the token keeps no linear
///      storage beyond ERC20Core's slots 0-2 (see README, storage layout).
abstract contract PermitExtension is IERC2612, IERC5267 {
    using UnstructuredRefStorage for bytes32;

    /// @dev Stores the dynamic metadata of the PermitExtension. Allows safely use of this
    ///     contract with upgradable proxies
    struct EIP5267Metadata {
        string name;
        string version;
    }

    /// @dev user nonce slot position.
    bytes32 internal constant NONCE_BY_ADDRESS_POSITION = keccak256("PermitExtension.NONCE_BY_ADDRESS_POSITION");

    /// @dev Typehash constant for ERC-2612 (Permit)
    /// keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 internal constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// @dev Location of the slot with EIP5267Metadata
    bytes32 private constant EIP5267_METADATA_SLOT = keccak256("PermitExtension.eip5267MetadataSlot");

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id and the
    // address that it corresponds to, in order to invalidate the cached domain separator if
    // the chain id changes or the code runs behind a proxy (address(this) != _CACHED_THIS).
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;
    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;

    /// @param name_ The name of the token
    /// @param version_ The current major version of the signing domain (aka token version)
    constructor(string memory name_, string memory version_) {
        _HASHED_NAME = keccak256(bytes(name_));
        _HASHED_VERSION = keccak256(bytes(version_));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_THIS = address(this);
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_HASHED_NAME, _HASHED_VERSION);
        _initializeEIP5267Metadata(name_, version_);
    }

    /// @notice Sets `value_` as the allowance of `spender_` over `owner_`'s tokens, given `owner_`'s signed approval.
    /// @param owner_  Token owner's address (Authorizer). Cannot be the zero address.
    /// @param spender_  An address of the tokens spender. Cannot be the zero address.
    /// @param value_ An amount of tokens to allow to spend.
    /// @param deadline_ The time at which the signature expires (unix time). Must be a timestamp in the future.
    /// @param v_, r_, s_ must be a valid `secp256k1` signature from `owner`
    ///                   over the EIP712-formatted function arguments.
    ///                   The signature must use ``owner``'s current nonce (see {nonces}).
    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external {
        _permit(owner_, spender_, value_, deadline_, abi.encodePacked(r_, s_, v_));
    }

    /// @notice Sets `value_` as the allowance of `spender_` over `owner_`'s tokens, given `owner_`'s signed approval.
    /// @param owner_  Token owner's address (Authorizer). Cannot be the zero address.
    /// @param spender_  An address of the tokens spender. Cannot be the zero address.
    /// @param value_ An amount of tokens to allow to spend.
    /// @param deadline_ The time at which the signature expires (unix time). Must be a timestamp in the future.
    /// @param signature_ Unstructured bytes signature signed by an EOA wallet or a contract wallet.
    function permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        bytes calldata signature_
    ) external {
        _permit(owner_, spender_, value_, deadline_, signature_);
    }

    function _permit(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_,
        bytes memory signature_
    ) internal {
        if (block.timestamp > deadline_) {
            revert ErrorDeadlineExpired();
        }

        bytes32 hash = _hashTypedDataV4(
            keccak256(
                abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, _useNonce(owner_), deadline_)
            )
        );

        if (!SignatureChecker.isValidSignatureNow(owner_, hash, signature_)) {
            revert ErrorInvalidSignature();
        }

        _permitAccepted(owner_, spender_, value_);
    }

    /// @dev Returns the current nonce for `owner`. This value must be
    /// included whenever a signature is generated for {permit}.
    ///
    /// Every successful call to {permit} increases ``owner``'s nonce by one. This
    /// prevents a signature from being used multiple times.
    ///
    function nonces(address owner) external view returns (uint256) {
        return _getNonceByAddress()[owner];
    }

    /// @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @dev EIP-5267. Returns the fields and values that describe the domain separator
    /// used by this contract for EIP-712 signature.
    function eip712Domain()
        external
        view
        virtual
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f", // 01111
            _loadEIP5267Metadata().name,
            _loadEIP5267Metadata().version,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    /// @notice Sets domain metadata only if it matches the domain used for signature verification.
    /// @param name_ The name of the token
    /// @param version_ The version of the token
    function _initializeEIP5267Metadata(string memory name_, string memory version_) internal {
        bytes32 domainSeparator = _buildDomainSeparator(keccak256(bytes(name_)), keccak256(bytes(version_)));
        if (domainSeparator != _domainSeparatorV4()) {
            revert ErrorEIP712DomainMismatch();
        }
        _setEIP5267MetadataName(name_);
        _setEIP5267MetadataVersion(version_);
        // ERC-5267: implementers MUST emit this whenever the advertised domain may have changed.
        emit EIP712DomainChanged();
    }

    /// @dev Returns the domain separator for the current chain and verifying contract.
    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_HASHED_NAME, _HASHED_VERSION);
        }
    }

    function _buildDomainSeparator(bytes32 hashedName_, bytes32 hashedVersion_) private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, hashedName_, hashedVersion_, block.chainid, address(this)));
    }

    /// @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct],
    /// this function returns the hash of the fully encoded EIP712 message for this domain.
    function _hashTypedDataV4(bytes32 structHash_) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash_);
    }

    /// @dev "Consume a nonce": return the current value and increment.
    function _useNonce(address _owner) internal returns (uint256 current) {
        current = _getNonceByAddress()[_owner];
        _getNonceByAddress()[_owner] = current + 1;
    }

    /// @notice Nonces for ERC-2612 (Permit)
    function _getNonceByAddress() internal pure returns (mapping(address => uint256) storage) {
        return NONCE_BY_ADDRESS_POSITION.storageMapAddressAddressUint256();
    }

    /// @dev Override this function in the inherited contract to invoke the approve() function of ERC20.
    function _permitAccepted(address owner_, address spender_, uint256 amount_) internal virtual;

    /// @dev Sets the name of the token. Might be called only when the name is empty
    function _setEIP5267MetadataName(string memory name_) internal {
        _loadEIP5267Metadata().name = name_;
    }

    /// @dev Sets the version of the token. Might be called only when the version is empty
    function _setEIP5267MetadataVersion(string memory version_) internal {
        _loadEIP5267Metadata().version = version_;
    }

    /// @dev Returns the reference to the slot with EIP5267Metadata struct
    function _loadEIP5267Metadata() private pure returns (EIP5267Metadata storage r) {
        bytes32 slot = EIP5267_METADATA_SLOT;
        assembly {
            r.slot := slot
        }
    }

    error ErrorInvalidSignature();
    error ErrorDeadlineExpired();
    error ErrorEIP712DomainMismatch();
}
