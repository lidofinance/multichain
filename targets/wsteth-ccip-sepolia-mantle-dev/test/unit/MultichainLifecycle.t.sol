// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {LockBoxRecords} from "../scenario/LockBoxRecords.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@chainlink/contracts/src/v0.8/shared/access/Ownable2Step.sol";
import {AuthorizedCallers} from "@chainlink/contracts/src/v0.8/shared/access/AuthorizedCallers.sol";
import {TokenPool} from "@chainlink/contracts-ccip/pools/TokenPool.sol";
import {SiloedLockReleaseTokenPool} from "@chainlink/contracts-ccip/pools/SiloedLockReleaseTokenPool.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/pools/ERC20LockBox.sol";
import {RateLimiter} from "@chainlink/contracts-ccip/libraries/RateLimiter.sol";
import {VersionedVerifierResolver} from "@chainlink/contracts-ccip/ccvs/VersionedVerifierResolver.sol";

contract LifecycleToken is ERC20 {
    constructor() ERC20("Test", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Expose custody internals to isolate the silo property from external ramp setup.
contract LifecyclePool is SiloedLockReleaseTokenPool {
    constructor(address token) SiloedLockReleaseTokenPool(IERC20(token), 18, address(0), address(1), address(2)) {}

    function lock(uint64 lane, uint256 amount) external {
        _lockOrBurn(lane, amount);
    }

    function release(uint64 lane, uint256 amount) external {
        _releaseOrMint(msg.sender, amount, lane);
    }
}

/// @notice Lane addition on a handed-over siloed hub, and resolver version management, as the
/// owner (the LidoTimelock in the deployment; here the owner principal itself, since the custody
/// and resolver properties under test do not depend on how the owner's call is scheduled).
contract MultichainLifecycleTest is Test {
    LifecycleToken token;
    LifecyclePool pool;
    address owner = address(0xDA0);

    function setUp() public {
        token = new LifecycleToken();
        pool = new LifecyclePool(address(token));
        pool.transferOwnership(owner);
        callAsOwner(address(pool), abi.encodeCall(Ownable2Step.acceptOwnership, ()));
    }

    function callAsOwner(address target, bytes memory data) internal {
        vm.prank(owner);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function addLane(uint64 selector) internal returns (ERC20LockBox box) {
        box = new ERC20LockBox(address(token));
        address[] memory callers = new address[](1);
        callers[0] = address(pool);
        box.applyAuthorizedCallerUpdates(AuthorizedCallers.AuthorizedCallerArgs(callers, new address[](0)));
        box.transferOwnership(owner);
        callAsOwner(address(box), abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        bytes[] memory remotePools = new bytes[](1);
        remotePools[0] = abi.encode(address(uint160(selector + 100)));
        updates[0] = TokenPool.ChainUpdate(
            selector,
            remotePools,
            abi.encode(address(uint160(selector + 200))),
            RateLimiter.Config(false, 0, 0),
            RateLimiter.Config(false, 0, 0)
        );
        callAsOwner(address(pool), abi.encodeCall(TokenPool.applyChainUpdates, (new uint64[](0), updates)));
        SiloedLockReleaseTokenPool.LockBoxConfig[] memory boxes = new SiloedLockReleaseTokenPool.LockBoxConfig[](1);
        boxes[0] = SiloedLockReleaseTokenPool.LockBoxConfig(selector, address(box));
        callAsOwner(address(pool), abi.encodeCall(SiloedLockReleaseTokenPool.configureLockBoxes, (boxes)));
    }

    function test_AddThirdLaneAfterHandoverPreservesExistingCustody() public {
        ERC20LockBox first = addLane(10);
        ERC20LockBox second = addLane(20);
        token.mint(address(pool), 30);
        pool.lock(10, 10);
        pool.lock(20, 20);
        ERC20LockBox third = addLane(30);
        assertEq(pool.getSupportedChains().length, 3);
        assertEq(address(pool.getLockBox(10)), address(first));
        assertEq(address(pool.getLockBox(20)), address(second));
        assertEq(address(pool.getLockBox(30)), address(third));
        vm.expectRevert(abi.encodeWithSelector(ERC20LockBox.InsufficientBalance.selector, 11, 10));
        pool.release(10, 11); // cannot borrow the other silo's 20 tokens
        assertEq(token.balanceOf(address(first)), 10);
        assertEq(token.balanceOf(address(second)), 20);
        assertEq(token.balanceOf(address(third)), 0);
        assertEq(pool.owner(), owner);
        assertEq(third.owner(), owner);
    }

    function test_ResolverCanReplaceAndRetireDummyThroughGovernance() public {
        VersionedVerifierResolver resolver = new VersionedVerifierResolver();
        resolver.transferOwnership(owner);
        callAsOwner(address(resolver), abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        VersionedVerifierResolver.InboundImplementationArgs[] memory incoming =
            new VersionedVerifierResolver.InboundImplementationArgs[](1);
        incoming[0] = VersionedVerifierResolver.InboundImplementationArgs(0xdecafbad, address(50));
        callAsOwner(
            address(resolver), abi.encodeCall(VersionedVerifierResolver.applyInboundImplementationUpdates, (incoming))
        );
        incoming[0] = VersionedVerifierResolver.InboundImplementationArgs(0x12345678, address(60));
        callAsOwner(
            address(resolver), abi.encodeCall(VersionedVerifierResolver.applyInboundImplementationUpdates, (incoming))
        );
        assertEq(resolver.getInboundImplementation(hex"decafbad"), address(50));
        assertEq(resolver.getInboundImplementation(hex"12345678"), address(60));
        incoming[0] = VersionedVerifierResolver.InboundImplementationArgs(0xdecafbad, address(0));
        callAsOwner(
            address(resolver), abi.encodeCall(VersionedVerifierResolver.applyInboundImplementationUpdates, (incoming))
        );
        assertEq(resolver.getInboundImplementation(hex"decafbad"), address(0));
        assertEq(resolver.getInboundImplementation(hex"12345678"), address(60));
    }

    function test_ForgeParsesRemoteNamesForOrderIndependentLockboxSelection() public pure {
        string memory record =
            '{"deployed":{"lock_boxes":[{"lock_box":"0x0000000000000000000000000000000000000001","remote_chain_name":"base_sepolia"},{"lock_box":"0x0000000000000000000000000000000000000002","remote_chain_name":"mantle_sepolia"}]}}';
        assertEq(LockBoxRecords.find(vm, record, "mantle_sepolia"), address(2));
        assertEq(LockBoxRecords.find(vm, record, "base_sepolia"), address(1));
    }
}
