// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/interfaces/IRouterClient.sol";
import {ITokenAdminRegistry} from "@chainlink/contracts-ccip/interfaces/ITokenAdminRegistry.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

/// @notice Adds a bridge mode, a CCIP send path and a one-vote migration schedule to the Lido
///     OP-stack token bridges (`L1ERC20TokenBridge`, `L2ERC20TokenBridge`), which are upgraded in
///     place. Sends are `depositERC20*` on L1 and `withdraw*` on L2; receives are
///     `finalizeERC20Withdrawal` on L1 and `finalizeDeposit` on L2.
///
///     LEGACY     sends and receives go through the Optimism cross-domain messenger, as before
///                the upgrade.
///     MIGRATING  sends go through CCIP; receives from the messenger still finalize, so
///                transfers started before the switch complete.
///     CCIP_ONLY  sends go through CCIP; receives from the messenger revert.
///
///     The forward path is driven by two timers the admin sets once, in the same governance
///     batch that upgrades the proxy: `scheduleActivation(T_activate)` and
///     `scheduleClose(T_close)`. After each timer anyone calls the matching permissionless step:
///
///     activate()  LEGACY → MIGRATING, once `T_activate` has passed, the token admin registry
///                 binds this chain's token to the expected CCIP pool, and the bridge's send
///                 switch (`isDepositsEnabled` on L1, `isWithdrawalsEnabled` on L2) is on.
///                 Switching that flag off (the Emergency Brakes hold the disabler role) vetoes
///                 the activation without a vote; switching it back on takes the admin.
///     close()     MIGRATING → CCIP_ONLY, once `T_close` has passed and the same send switch is
///                 on. The same flag vetoes the close while legacy transfers are still in flight.
///
///     Both steps run once. `switchBridgeMode` stays admin-only for rollbacks and never re-arms
///     them, so a rollback cannot be undone by a stranger replaying `activate()`.
///
///     A CCIP send is a token-only transfer: the Router pulls the tokens into the lane's token
///     pool on this chain and the pool on the destination chain credits `to_`. The message has no
///     payload and a zero gas limit, so CCIP never calls `to_`, and this contract has no
///     `ccipReceive`. The legacy `data_` argument keeps its meaning: recorded in the legacy
///     events, never delivered.
///
/// @dev The mode and the schedule live in one ERC-7201 namespaced slot, so the storage layout of
///     the previous implementation is unchanged: `AccessControl._roles` stays at slot 0 and the
///     `BridgingManager` state at its own keccak slot. This contract adds no linear storage.
abstract contract CCIPMigrationSender {
    using SafeERC20 for IERC20;

    enum BridgeMode {
        LEGACY,
        MIGRATING,
        CCIP_ONLY
    }

    /// @custom:storage-location erc7201:lido.storage.CCIPMigrationSender
    /// @dev One slot: mode (1 byte), two timers (8 bytes each), two one-shot flags,
    ///      and the authenticated L1 activation confirmation used on L2.
    struct MigrationStorage {
        BridgeMode mode;
        uint64 activateAt;
        uint64 closeAt;
        bool activated;
        bool closed;
        bool l1ActivationConfirmed;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("lido.storage.CCIPMigrationSender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MIGRATION_STORAGE_SLOT =
        0x5f13d1d6525b00150ceb4a1ca6bb5b19096fea6f8da7e4e62c48db5202dc7b00;

    /// @notice CCIP Router on this chain
    IRouterClient public immutable ccipRouter;

    /// @notice CCIP chain selector of the chain on the other side of this bridge
    uint64 public immutable ccipDestinationChainSelector;

    /// @notice CCIP TokenAdminRegistry on this chain; `activate()` reads the pool bound to the token
    ITokenAdminRegistry public immutable ccipTokenAdminRegistry;

    /// @notice The CCIP token pool the registry must bind to the bridged token before `activate()`
    address public immutable ccipTokenPool;

    /// @param router_ CCIP Router on this chain
    /// @param destinationChainSelector_ CCIP chain selector of the chain on the other side of this
    ///     bridge
    /// @param tokenAdminRegistry_ CCIP TokenAdminRegistry on this chain
    /// @param tokenPool_ The CCIP token pool expected to serve the bridged token on this chain
    constructor(address router_, uint64 destinationChainSelector_, address tokenAdminRegistry_, address tokenPool_) {
        if (router_ == address(0) || tokenAdminRegistry_ == address(0) || tokenPool_ == address(0)) {
            revert ErrorZeroAddress();
        }
        if (destinationChainSelector_ == 0) {
            revert ErrorZeroChainSelector();
        }
        ccipRouter = IRouterClient(router_);
        ccipDestinationChainSelector = destinationChainSelector_;
        ccipTokenAdminRegistry = ITokenAdminRegistry(tokenAdminRegistry_);
        ccipTokenPool = tokenPool_;
    }

    // ── mode ──────────────────────────────────────────────────────────────────────────────────

    /// @notice Current bridge mode. A proxy upgraded to this implementation starts in LEGACY, the
    ///     zero value.
    function getBridgeMode() public view returns (BridgeMode) {
        return _loadMigrationStorage().mode;
    }

    /// @notice Reverts unless the bridge is in `expected_`. Meant as the first call of a governance
    ///     batch that switches the mode, so a replayed or stale batch reverts instead of switching
    ///     twice.
    function requireBridgeMode(BridgeMode expected_) external view {
        _requireMode(expected_);
    }

    /// @notice Switches the bridge mode directly. The scheduled path is `activate()` and `close()`;
    ///     this is the admin's rollback lever and allows every transition between distinct modes.
    ///     It does not re-arm `activate()` or `close()`.
    function switchBridgeMode(BridgeMode newMode_) external {
        _onlyAdmin();
        MigrationStorage storage $ = _loadMigrationStorage();
        BridgeMode oldMode = $.mode;
        if (oldMode == newMode_) {
            revert ErrorSameBridgeMode(newMode_);
        }
        $.mode = newMode_;
        emit BridgeModeUpdated(msg.sender, oldMode, newMode_);
    }

    // ── schedule ──────────────────────────────────────────────────────────────────────────────

    /// @notice Timestamp from which anyone may call `activate()`; 0 while not scheduled
    function getActivationTime() public view returns (uint256) {
        return _loadMigrationStorage().activateAt;
    }

    /// @notice Timestamp from which anyone may call `close()`; 0 while not scheduled
    function getCloseTime() public view returns (uint256) {
        return _loadMigrationStorage().closeAt;
    }

    /// @notice Whether `activate()` has run
    function isActivated() public view returns (bool) {
        return _loadMigrationStorage().activated;
    }

    /// @notice Whether `close()` has run
    function isClosed() public view returns (bool) {
        return _loadMigrationStorage().closed;
    }

    /// @notice Sets the time from which `activate()` may run. Admin only, once, in LEGACY, in the
    ///     future.
    function scheduleActivation(uint256 activateAt_) external {
        _onlyAdmin();
        _requireMode(BridgeMode.LEGACY);
        MigrationStorage storage $ = _loadMigrationStorage();
        if ($.activateAt != 0) {
            revert ErrorAlreadyScheduled();
        }
        if (activateAt_ <= block.timestamp || activateAt_ > type(uint64).max) {
            revert ErrorInvalidSchedule(activateAt_);
        }
        $.activateAt = uint64(activateAt_);
        emit ActivationScheduled(msg.sender, activateAt_);
    }

    /// @notice Sets the time from which `close()` may run. Admin only, once, after the activation
    ///     has been scheduled, later than the activation time.
    function scheduleClose(uint256 closeAt_) external {
        _onlyAdmin();
        MigrationStorage storage $ = _loadMigrationStorage();
        if ($.activateAt == 0) {
            revert ErrorActivationNotScheduled();
        }
        if ($.closeAt != 0) {
            revert ErrorAlreadyScheduled();
        }
        if (closeAt_ <= $.activateAt || closeAt_ > type(uint64).max) {
            revert ErrorInvalidSchedule(closeAt_);
        }
        $.closeAt = uint64(closeAt_);
        emit CloseScheduled(msg.sender, closeAt_);
    }

    /// @notice LEGACY → MIGRATING. Anyone, once, after the activation time, while the bridge's send
    ///     switch is on and the token admin registry binds the token to `ccipTokenPool`. Runs the
    ///     chain-specific `_afterActivate` hook (L1: moves escrow and sends confirmation;
    ///     L2: requires that confirmation). A hook failure reverts the whole activation.
    function activate() external {
        MigrationStorage storage $ = _loadMigrationStorage();
        if ($.activateAt == 0) {
            revert ErrorActivationNotScheduled();
        }
        if ($.activated) {
            revert ErrorAlreadyActivated();
        }
        if (block.timestamp < $.activateAt) {
            revert ErrorTooEarly($.activateAt);
        }
        _requireMode(BridgeMode.LEGACY);
        address pool = ccipTokenAdminRegistry.getPool(_token());
        if (pool != ccipTokenPool) {
            revert ErrorUnexpectedTokenPool(pool, ccipTokenPool);
        }
        if (!_sendsEnabled()) {
            revert ErrorSendsDisabled();
        }
        $.activated = true;
        $.mode = BridgeMode.MIGRATING;
        emit BridgeModeUpdated(msg.sender, BridgeMode.LEGACY, BridgeMode.MIGRATING);
        emit Activated(msg.sender);
        _afterActivate();
    }

    /// @notice MIGRATING → CCIP_ONLY. Anyone, once, after the close time, while the bridge's send
    ///     switch is on. Runs the chain-specific `_afterClose` hook (on L2: renounces the token's
    ///     mint and burn roles).
    function close() external {
        MigrationStorage storage $ = _loadMigrationStorage();
        if ($.closeAt == 0) {
            revert ErrorCloseNotScheduled();
        }
        if ($.closed) {
            revert ErrorAlreadyClosed();
        }
        if (block.timestamp < $.closeAt) {
            revert ErrorTooEarly($.closeAt);
        }
        _requireMode(BridgeMode.MIGRATING);
        if (!_sendsEnabled()) {
            revert ErrorSendsDisabled();
        }
        $.closed = true;
        $.mode = BridgeMode.CCIP_ONLY;
        emit BridgeModeUpdated(msg.sender, BridgeMode.MIGRATING, BridgeMode.CCIP_ONLY);
        emit Closed(msg.sender);
        _afterClose();
    }

    // ── CCIP send ─────────────────────────────────────────────────────────────────────────────

    /// @notice Native-token fee the Router charges for sending `amount_` to `to_`; 0 in LEGACY
    ///     mode. A send must be called with at least this much `msg.value`. The excess is refunded
    ///     to the caller with a plain call, so a contract that overpays must be able to receive
    ///     ether. The quote changes between blocks, so pay a margin above it.
    /// @param to_ Recipient on the destination chain
    /// @param amount_ Amount of the bridged token
    function getCCIPFee(address to_, uint256 amount_) external view returns (uint256) {
        if (getBridgeMode() == BridgeMode.LEGACY) {
            return 0;
        }
        return ccipRouter.getFee(ccipDestinationChainSelector, _buildMessage(to_, amount_));
    }

    /// @dev Pulls `amount_` of the bridged token from `msg.sender`, who must have approved this
    ///     contract for it, sends the tokens through the Router and refunds the part of
    ///     `msg.value` above the quoted fee. Reverts in LEGACY mode.
    /// @param to_ Recipient on the destination chain
    /// @param amount_ Amount of the bridged token
    function _ccipSend(address to_, uint256 amount_)
        internal
        whenNotMode(BridgeMode.LEGACY)
        returns (bytes32 messageId)
    {
        IERC20 token = IERC20(_token());
        token.safeTransferFrom(msg.sender, address(this), amount_);
        token.forceApprove(address(ccipRouter), amount_);

        Client.EVM2AnyMessage memory message = _buildMessage(to_, amount_);
        uint256 fee = ccipRouter.getFee(ccipDestinationChainSelector, message);
        if (msg.value < fee) {
            revert ErrorInsufficientCCIPFee(fee, msg.value);
        }

        messageId = ccipRouter.ccipSend{value: fee}(ccipDestinationChainSelector, message);
        emit CCIPTransferInitiated(messageId, msg.sender, to_, amount_, fee);

        if (msg.value > fee) {
            Address.sendValue(payable(msg.sender), msg.value - fee);
        }
    }

    /// @dev Token-only message: no payload and a zero gas limit, so CCIP credits `to_` without
    ///     calling it. Out-of-order execution is allowed; this bridge does not depend on delivery
    ///     order.
    function _buildMessage(address to_, uint256 amount_) internal view returns (Client.EVM2AnyMessage memory message) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token(), amount: amount_});

        message = Client.EVM2AnyMessage({
            receiver: abi.encode(to_),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}))
        });
    }

    // ── internals ─────────────────────────────────────────────────────────────────────────────

    /// @dev Reverts while the bridge is in `mode_`
    modifier whenNotMode(BridgeMode mode_) {
        BridgeMode current = getBridgeMode();
        if (current == mode_) {
            revert ErrorBridgeModeNotAllowed(current);
        }
        _;
    }

    function _requireMode(BridgeMode expected_) internal view {
        BridgeMode current = getBridgeMode();
        if (current != expected_) {
            revert ErrorUnexpectedBridgeMode(current, expected_);
        }
    }

    /// @dev Reverts unless `msg.sender` is the bridge admin
    function _onlyAdmin() internal view virtual;

    /// @dev The bridged token on this chain
    function _token() internal view virtual returns (address);

    /// @dev The bridge's send switch on this chain (`isDepositsEnabled` on L1, `isWithdrawalsEnabled`
    ///     on L2); `activate()` and `close()` require it on
    function _sendsEnabled() internal view virtual returns (bool);

    /// @dev Chain-specific effect of `activate()`, after the mode switch
    function _afterActivate() internal virtual {}

    /// @dev Chain-specific effect of `close()`, after the mode switch
    function _afterClose() internal virtual {}

    function _loadMigrationStorage() internal pure returns (MigrationStorage storage $) {
        bytes32 slot = MIGRATION_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    /// @notice Emitted on every mode switch, scheduled or direct
    event BridgeModeUpdated(address indexed admin, BridgeMode oldMode, BridgeMode newMode);

    /// @notice Emitted once by `scheduleActivation`
    event ActivationScheduled(address indexed admin, uint256 activateAt);

    /// @notice Emitted once by `scheduleClose`
    event CloseScheduled(address indexed admin, uint256 closeAt);

    /// @notice Emitted once by `activate()`
    event Activated(address indexed caller);

    /// @notice Emitted once by `close()`
    event Closed(address indexed caller);

    /// @notice Emitted on every CCIP send. `fee` is the native-token fee paid to the Router.
    event CCIPTransferInitiated(
        bytes32 indexed messageId, address indexed from, address indexed to, uint256 amount, uint256 fee
    );

    error ErrorZeroAddress();
    error ErrorZeroChainSelector();
    error ErrorSameBridgeMode(BridgeMode mode);
    error ErrorUnexpectedBridgeMode(BridgeMode current, BridgeMode expected);
    error ErrorBridgeModeNotAllowed(BridgeMode current);
    /// @dev `msg.value` is below the fee the Router quoted for this send
    error ErrorInsufficientCCIPFee(uint256 required, uint256 provided);
    /// @dev `msg.value` must be zero while the bridge is in LEGACY mode
    error ErrorValueNotAccepted();
    /// @dev The timer has already been set
    error ErrorAlreadyScheduled();
    /// @dev The time is not in the future (activation) or not after the activation time (close)
    error ErrorInvalidSchedule(uint256 at);
    error ErrorActivationNotScheduled();
    error ErrorCloseNotScheduled();
    error ErrorAlreadyActivated();
    error ErrorAlreadyClosed();
    /// @dev `block.timestamp` is before the scheduled time
    error ErrorTooEarly(uint256 scheduledAt);
    /// @dev The token admin registry binds the token to another pool (or none)
    error ErrorUnexpectedTokenPool(address actual, address expected);
    /// @dev The bridge's send switch is off: the step is vetoed until the admin turns it back on
    error ErrorSendsDisabled();
}
