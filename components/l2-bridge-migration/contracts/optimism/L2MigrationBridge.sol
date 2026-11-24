// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IL2MintBurnToken} from "./interfaces/IL2MintBurnToken.sol";
import {L2ERC20TokenBridge} from "./L2ERC20TokenBridge.sol";
import {CCIPMigrationSender} from "./CCIPMigrationSender.sol";
import {IAdvancedPoolHooks} from "@chainlink/contracts-ccip/interfaces/IAdvancedPoolHooks.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";

interface IMigrationPoolHooks {
    function getAdvancedPoolHooks() external view returns (address);
}

/// @notice Implementation for the Lido L2 token bridge proxy (`L2ERC20TokenBridge`), upgraded in
///     place. Keeps the ABI and storage of the previous implementation and adds the bridge mode,
///     the scheduled migration and the CCIP send path. The bridge holds no tokens, so there is no
///     liquidity to move.
///
///     withdraw*        LEGACY: burnFrom + messenger   MIGRATING / CCIP_ONLY: Router send (payable)
///     finalizeDeposit  LEGACY / MIGRATING: mint       CCIP_ONLY: reverts
///     close()          CCIP_ONLY, then renounces the token's MINTER_ROLE and BURNER_ROLE
///
///     Both withdraw paths pull the tokens with an allowance from the caller to this bridge. The
///     legacy paths call `mint` and `burnFrom` on the token, so they also need this bridge to hold
///     the token's MINTER_ROLE and BURNER_ROLE; `close()` gives them up, so after it the token is
///     minted and burned by the CCIP pool only, whatever the mode.
contract L2MigrationBridge is L2ERC20TokenBridge, CCIPMigrationSender, IPolicyEngine {
    error ErrorL1ActivationNotConfirmed();
    error ErrorMigrationNotActivated();
    error ErrorUnexpectedPolicyCaller();
    error ErrorUnexpectedPolicyPayload();
    event L1ActivationConfirmed();

    /// @notice Confirms that the L1 bridge moved its escrow into the lane lockbox.
    /// @dev Only the canonical messenger carrying the immutable L1 bridge's message
    /// can set this flag. Duplicate delivery is harmless; it does not activate Base.
    function confirmL1Activation() external onlyFromCrossDomainAccount(l1TokenBridge) {
        MigrationStorage storage $ = _loadMigrationStorage();
        if (!$.l1ActivationConfirmed) {
            $.l1ActivationConfirmed = true;
            emit L1ActivationConfirmed();
        }
    }

    function isL1ActivationConfirmed() public view returns (bool) {
        return _loadMigrationStorage().l1ActivationConfirmed;
    }

    /// @dev Installed on the existing pool hooks in the atomic Base action set.
    /// The pool calls this for Router sends too, so bypassing the bridge cannot
    /// burn tokens before the L1 confirmation and Base activation. Inbound mints
    /// stay available: their corresponding L1 transfers already fund the lockbox.
    function run(IPolicyEngine.Payload calldata payload) external view override {
        _checkPolicyCaller();
        if (payload.sender != ccipTokenPool) revert ErrorUnexpectedPolicyPayload();
        if (payload.selector == IAdvancedPoolHooks.preflightCheck.selector) {
            if (!isActivated()) revert ErrorMigrationNotActivated();
        } else if (payload.selector != IAdvancedPoolHooks.postflightCheck.selector) {
            revert ErrorUnexpectedPolicyPayload();
        }
    }

    function attach() external view override {
        _checkPolicyCaller();
    }

    function detach() external view override {
        _checkPolicyCaller();
    }

    function _checkPolicyCaller() internal view {
        if (msg.sender != IMigrationPoolHooks(ccipTokenPool).getAdvancedPoolHooks()) {
            revert ErrorUnexpectedPolicyCaller();
        }
    }

    function _afterActivate() internal view override {
        if (!isL1ActivationConfirmed()) revert ErrorL1ActivationNotConfirmed();
    }
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @param messenger_ L2 messenger address being used for cross-chain communications
    /// @param l1TokenBridge_ Address of the corresponding L1 bridge
    /// @param l1Token_ Address of the bridged token in the L1 chain
    /// @param l2Token_ Address of the token minted on the L2 chain when token bridged
    /// @param router_ CCIP Router on L2
    /// @param destinationChainSelector_ CCIP chain selector of L1
    /// @param tokenAdminRegistry_ CCIP TokenAdminRegistry on L2
    /// @param tokenPool_ The CCIP burn-mint pool expected to serve `l2Token_`
    constructor(
        address messenger_,
        address l1TokenBridge_,
        address l1Token_,
        address l2Token_,
        address router_,
        uint64 destinationChainSelector_,
        address tokenAdminRegistry_,
        address tokenPool_
    )
        L2ERC20TokenBridge(messenger_, l1TokenBridge_, l1Token_, l2Token_)
        CCIPMigrationSender(router_, destinationChainSelector_, tokenAdminRegistry_, tokenPool_)
    {
        _lockInitialization();
    }

    /// @inheritdoc L2ERC20TokenBridge
    /// @dev Finalizes legacy deposits in LEGACY and MIGRATING; reverts in CCIP_ONLY
    function finalizeDeposit(
        address l1Token_,
        address l2Token_,
        address from_,
        address to_,
        uint256 amount_,
        bytes calldata data_
    ) public override whenNotMode(BridgeMode.CCIP_ONLY) {
        super.finalizeDeposit(l1Token_, l2Token_, from_, to_, amount_, data_);
    }

    /// @dev In LEGACY mode `msg.value` must be zero and the inherited path runs: burn from the
    ///     caller, send over the messenger. In the other modes the tokens are sent through CCIP.
    ///     `from_` is always `msg.sender` (see `withdraw` and `withdrawTo`), which is where the
    ///     CCIP path pulls the tokens from. Both paths emit `WithdrawalInitiated`; the CCIP path
    ///     also emits `CCIPTransferInitiated`, and `l1Gas_` and `data_` are only recorded in the
    ///     event.
    function _initiateWithdrawal(address from_, address to_, uint256 amount_, uint32 l1Gas_, bytes calldata data_)
        internal
        override
    {
        if (getBridgeMode() == BridgeMode.LEGACY) {
            if (msg.value != 0) {
                revert ErrorValueNotAccepted();
            }
            super._initiateWithdrawal(from_, to_, amount_, l1Gas_, data_);
        } else {
            _ccipSend(to_, amount_);
            emit WithdrawalInitiated(l1Token, l2Token, from_, to_, amount_, data_);
        }
    }

    /// @dev The legacy paths are closed for good: the bridge gives up the token's mint and burn
    ///     roles (a no-op for a role it does not hold). Re-granting them is the token admin's call.
    function _afterClose() internal override {
        IL2MintBurnToken(l2Token).renounceRole(MINTER_ROLE, address(this));
        IL2MintBurnToken(l2Token).renounceRole(BURNER_ROLE, address(this));
        emit TokenRolesRenounced(l2Token);
    }

    /// @dev Mode switches and the schedule require DEFAULT_ADMIN_ROLE on this bridge
    function _onlyAdmin() internal view override {
        _checkRole(DEFAULT_ADMIN_ROLE);
    }

    function _token() internal view override returns (address) {
        return l2Token;
    }

    /// @dev The L2 send switch; the Emergency Brakes can turn it off
    function _sendsEnabled() internal view override returns (bool) {
        return isWithdrawalsEnabled();
    }

    /// @notice Emitted once by `close()`: MINTER_ROLE and BURNER_ROLE renounced on `token`
    event TokenRolesRenounced(address indexed token);
}
