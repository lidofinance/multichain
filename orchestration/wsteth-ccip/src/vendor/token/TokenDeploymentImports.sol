// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Keep the L2 token implementation in profile.token's source graph so forge verification can
// resolve its compiler input and the deployment build resolves its bytecode:
//   - ERC20BridgedPermit (components/wsteth-token, OZ 5.0.2 contracts + upgradeable)
// The TransparentUpgradeableProxy + ProxyAdmin it is deployed behind are deliberately NOT imported
// here: components/wsteth-token compiles them from its own root (the OZ 5.3.0 submodule is in its
// lib/) so their metadata carries relative source names rather than this checkout's absolute path.
import {ERC20BridgedPermit} from "@wsteth-token/contracts/token/ERC20BridgedPermit.sol";
