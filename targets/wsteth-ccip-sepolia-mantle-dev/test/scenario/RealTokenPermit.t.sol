// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BridgeScenarioBase} from "./BridgeScenarioBase.sol";

interface IPermitToken {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function getContractVersion() external view returns (uint256);
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @title RealTokenPermit — the EIP-2612 surface the L2 token was swapped to `ERC20BridgedPermit` for.
/// @notice Everything else in this repo checks the token through CCIP: the pool mints, the pool burns,
/// state-mate counts the role holders. None of that touches `permit`, which is the only reason the token
/// source changed at all (see docs/adr/l2-token-contract.md). These tests run against the token ALREADY
/// DEPLOYED on the fork — same substrate rule as the other Real* harnesses — so they check the deployed
/// bytecode, not a fresh in-test instance that could differ from it.
contract RealTokenPermitTest is BridgeScenarioBase {
    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    bytes4 internal constant ERROR_DEADLINE_EXPIRED = bytes4(keccak256("ErrorDeadlineExpired()"));
    bytes4 internal constant ERROR_INVALID_SIGNATURE = bytes4(keccak256("ErrorInvalidSignature()"));

    /// @dev keccak256("wsteth-2.0 RealTokenPermit owner") -> 0x3CF5807C903F7E74045992a1f5F805ECe8A42480.
    /// Deliberately a high-entropy key rather than `makeAddrAndKey` or a vanity number, for a reason
    /// that is not cosmetic. `PermitExtension` verifies through OZ `SignatureChecker`, so a signature
    /// that does NOT recover to `owner` falls through to an ERC-1271 `isValidSignature` STATICCALL on
    /// `owner` itself — which is exactly what the replay test exercises. In fork mode Foundry aborts a
    /// call to a code-less address it recognises (a `makeAddr` label, or an address that carries code
    /// on one of the OTHER forks), and that abort masks the token's own revert. A vanity key does the
    /// second: `vm.addr(0xA11CE)` is a live Sepolia account with an EIP-7702 delegation, so it is a
    /// "contract" on the L1 fork and code-less on the L2 one. This key is untouched on both chains.
    uint256 internal constant OWNER_KEY = 0x3e132cb1e13ccd32ecddf59317eaf258c4f7e71205d62f7821d7d3a4429be73e;

    IPermitToken internal token;
    address internal owner;
    uint256 internal ownerKey;
    address internal spender = makeAddr("permitSpender");

    function setUp() public {
        _setUpForksAndRecord();
        vm.selectFork(l2Fork);
        token = IPermitToken(l2.token);
        ownerKey = OWNER_KEY;
        owner = vm.addr(ownerKey);
        vm.deal(owner, 1 ether);
    }

    /// @dev Builds the signature the way a wallet would: domain read OFF-CHAIN-STYLE from the token,
    /// struct hash assembled locally. A domain mismatch between what the token advertises and what it
    /// verifies against shows up here as a rejected signature.
    function _sign(uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    /// @notice The happy path: an off-chain signature grants an allowance without the owner sending a tx.
    function test_permit_grants_allowance_and_consumes_nonce() public {
        uint256 value = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);
        assertEq(token.allowance(owner, spender), 0, "precondition: no allowance");

        (uint8 v, bytes32 r, bytes32 s) = _sign(value, nonce, deadline);
        // Submitted by a third party, which is the whole point of permit — the owner never transacts.
        vm.prank(recipient);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value, "allowance not set");
        assertEq(token.nonces(owner), nonce + 1, "nonce not consumed");
    }

    /// @notice A consumed signature cannot be replayed: the nonce it committed to is spent, so the
    /// recovered signer no longer matches.
    function test_permit_replay_reverts() public {
        // A rejected signature reaches the ERC-1271 fallback, which STATICCALLs `owner` (see
        // OWNER_KEY). Foundry's fork mode refuses a call to a code-less address and that refusal
        // would stand in for the token's own revert, so give `owner` a single STOP opcode: the
        // staticcall then succeeds with empty returndata, which is byte-for-byte what an EOA
        // returns, and SignatureChecker rejects it for the same reason (returndata is not 32 bytes).
        // The path under test — nonce consumed, signature no longer valid — is unchanged.
        vm.etch(owner, hex"00");
        uint256 value = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(value, token.nonces(owner), deadline);
        token.permit(owner, spender, value, deadline, v, r, s);

        vm.expectRevert(ERROR_INVALID_SIGNATURE);
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    /// @notice An expired deadline is rejected before the signature is even recovered.
    function test_permit_expired_deadline_reverts() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(1 ether, token.nonces(owner), deadline);

        vm.expectRevert(ERROR_DEADLINE_EXPIRED);
        token.permit(owner, spender, 1 ether, deadline, v, r, s);
    }

    /// @notice The domain the token ADVERTISES (eip712Domain, proxy storage, written by the initializer)
    /// must produce the separator the token VERIFIES against (DOMAIN_SEPARATOR, built from the
    /// implementation's constructor immutables). Nothing in the contracts couples the two — the deploy
    /// script passes the same constants to both — so a drift would silently reject every wallet
    /// signature while leaving no bad state to inspect. Step 03 asserts this at deploy time; this
    /// re-asserts it against whatever is actually on the chain now.
    function test_eip712_domain_is_coherent() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(verifyingContract, address(token), "domain must bind the proxy, not the implementation");
        assertEq(chainId, block.chainid, "domain chainId");

        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected, "advertised domain != verified domain");
        assertEq(token.getContractVersion(), 2, "contract version");
    }

    /// @notice The legacy `bridge` mint/burn authority is gone from the DEPLOYED bytecode
    /// (removed upstream in the pinned base, lib/lido-l2-with-steth @ feat/token-upgrade; it was
    /// patches/lido-l2-with-steth/0001 until 2026-09-02). It is an immutable, so had it survived it
    /// would be a second
    /// mint principal that no governance action could ever revoke — and one that state-mate's role
    /// cardinality checks cannot see, because it is not a role.
    function test_token_exposes_no_legacy_bridge_authority() public view {
        (bool ok,) = address(token).staticcall(abi.encodeWithSignature("bridge()"));
        assertFalse(ok, "token still exposes bridge()");
        (ok,) = address(token).staticcall(abi.encodeWithSignature("bridgeMint(address,uint256)", recipient, 1));
        assertFalse(ok, "token still exposes bridgeMint()");
    }
}
