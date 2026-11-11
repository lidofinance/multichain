// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILockBox} from "@chainlink/contracts-ccip/interfaces/ILockBox.sol";

import {L1ERC20TokenBridge} from "./L1ERC20TokenBridge.sol";
import {CCIPMigrationSender} from "./CCIPMigrationSender.sol";

/// @notice Implementation for the Lido L1 token bridge proxy (`L1ERC20TokenBridge`), upgraded in
///     place. Keeps the ABI and storage of the previous implementation and adds the bridge mode,
///     the scheduled migration and the CCIP send path. The lane's `ERC20LockBox` on this chain
///     becomes the single backing for both withdrawal paths once the bridge is activated.
///
///     depositERC20*            LEGACY: lock here + messenger   MIGRATING / CCIP_ONLY: Router send (payable)
///     activate()               moves the whole escrow to the lockbox, then MIGRATING
///     finalizeERC20Withdrawal  LEGACY: pays from the escrow   MIGRATING: pays from the escrow,
///                              drawing the shortfall from the lockbox   CCIP_ONLY: reverts
///
///     Drawing from the lockbox needs this bridge on its authorized-caller list (the lockbox owner,
///     the Lido timelock, adds it in the same vote). The lockbox's `withdraw` is balance-based and
///     ignores the chain selector, so the bridge and the CCIP hub pool share one balance.
contract L1MigrationBridge is L1ERC20TokenBridge, CCIPMigrationSender {
    using SafeERC20 for IERC20;

    uint32 public constant ACTIVATION_CONFIRMATION_GAS = 200_000;

    /// @notice The lane lockbox on this chain: receives the escrow on `activate()` and funds legacy
    ///     withdrawals while MIGRATING
    ILockBox public immutable ccipLockBox;

    /// @param messenger_ L1 messenger address being used for cross-chain communications
    /// @param l2TokenBridge_ Address of the corresponding L2 bridge
    /// @param l1Token_ Address of the bridged token in the L1 chain
    /// @param l2Token_ Address of the token minted on the L2 chain when token bridged
    /// @param router_ CCIP Router on L1
    /// @param destinationChainSelector_ CCIP chain selector of the L2
    /// @param tokenAdminRegistry_ CCIP TokenAdminRegistry on L1
    /// @param tokenPool_ The CCIP hub pool expected to serve `l1Token_`
    /// @param lockBox_ The hub pool's lockbox for the L2 lane
    constructor(
        address messenger_,
        address l2TokenBridge_,
        address l1Token_,
        address l2Token_,
        address router_,
        uint64 destinationChainSelector_,
        address tokenAdminRegistry_,
        address tokenPool_,
        address lockBox_
    )
        L1ERC20TokenBridge(messenger_, l2TokenBridge_, l1Token_, l2Token_)
        CCIPMigrationSender(router_, destinationChainSelector_, tokenAdminRegistry_, tokenPool_)
    {
        if (lockBox_ == address(0)) {
            revert ErrorZeroAddress();
        }
        ccipLockBox = ILockBox(lockBox_);
        _lockInitialization();
    }

    /// @inheritdoc L1ERC20TokenBridge
    /// @dev LEGACY: from the escrow. MIGRATING: from the escrow, drawing what is missing from the
    ///     lockbox first. CCIP_ONLY: reverts. The legacy checks are repeated here so that nothing is
    ///     drawn for a call that the inherited function would reject.
    function finalizeERC20Withdrawal(
        address l1Token_,
        address l2Token_,
        address from_,
        address to_,
        uint256 amount_,
        bytes calldata data_
    )
        public
        override
        whenNotMode(BridgeMode.CCIP_ONLY)
        whenWithdrawalsEnabled
        onlySupportedL1Token(l1Token_)
        onlySupportedL2Token(l2Token_)
        onlyFromCrossDomainAccount(l2TokenBridge)
    {
        if (getBridgeMode() == BridgeMode.MIGRATING) {
            uint256 balance = IERC20(l1Token).balanceOf(address(this));
            if (amount_ > balance) {
                uint256 shortfall = amount_ - balance;
                ccipLockBox.withdraw(l1Token, ccipDestinationChainSelector, shortfall, address(this));
                emit EscrowReplenished(address(ccipLockBox), shortfall);
            }
        }
        super.finalizeERC20Withdrawal(l1Token_, l2Token_, from_, to_, amount_, data_);
    }

    /// @dev In LEGACY mode `msg.value` must be zero and the inherited path runs: lock here, send
    ///     over the messenger. In the other modes the tokens are sent through CCIP. `from_` is
    ///     always `msg.sender` (see `depositERC20` and `depositERC20To`), which is where the CCIP
    ///     path pulls the tokens from. Both paths emit `ERC20DepositInitiated`; the CCIP path also
    ///     emits `CCIPTransferInitiated`, and `l2Gas_` and `data_` are only recorded in the event.
    function _initiateERC20Deposit(address from_, address to_, uint256 amount_, uint32 l2Gas_, bytes calldata data_)
        internal
        override
    {
        if (getBridgeMode() == BridgeMode.LEGACY) {
            if (msg.value != 0) {
                revert ErrorValueNotAccepted();
            }
            super._initiateERC20Deposit(from_, to_, amount_, l2Gas_, data_);
        } else {
            _ccipSend(to_, amount_);
            emit ERC20DepositInitiated(l1Token, l2Token, from_, to_, amount_, data_);
        }
    }

    /// @dev The whole escrow goes to the lockbox by plain transfer; the lockbox counts balance,
    ///     not deposits. Legacy withdrawals still in flight are paid from there (see
    ///     `finalizeERC20Withdrawal`).
    function _afterActivate() internal override {
        uint256 balance = IERC20(l1Token).balanceOf(address(this));
        if (balance != 0) {
            IERC20(l1Token).safeTransfer(address(ccipLockBox), balance);
        }
        emit EscrowMigrated(address(ccipLockBox), balance);
        // The confirmation and the escrow transfer are one L1 transaction. A veto or
        // a failed transfer cannot leave an activation message for Base to consume.
        sendCrossDomainMessage(
            l2TokenBridge, ACTIVATION_CONFIRMATION_GAS, abi.encodeWithSignature("confirmL1Activation()")
        );
    }

    /// @dev Mode switches and the schedule require DEFAULT_ADMIN_ROLE on this bridge
    function _onlyAdmin() internal view override {
        _checkRole(DEFAULT_ADMIN_ROLE);
    }

    function _token() internal view override returns (address) {
        return l1Token;
    }

    /// @dev The L1 send switch; the Emergency Brakes can turn it off
    function _sendsEnabled() internal view override returns (bool) {
        return isDepositsEnabled();
    }

    /// @notice Emitted once by `activate()`: the escrow moved to the lockbox
    event EscrowMigrated(address indexed lockBox, uint256 amount);

    /// @notice Emitted when a legacy withdrawal draws `amount` from the lockbox
    event EscrowReplenished(address indexed lockBox, uint256 amount);
}
