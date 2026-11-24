// SPDX-FileCopyrightText: 2022 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev TEST-ONLY copy of the token the Base and Arbitrum wstETH proxies run today: lido-l2
///     `ERC20Bridged` + `ERC20Core` + `ERC20Metadata` at commit 082e7eb59de63bd376b30886568813408d04f00b
///     (`contracts/token/`). Changes from upstream: pragma 0.8.10 → 0.8.26, contracts renamed with a
///     `Legacy` prefix, the three files and two interfaces merged into one. Storage writes are
///     unchanged: ERC20Core in linear slots 0-2, metadata at keccak256("ERC20Metdata.dynamicMetadata"),
///     no Versioned slot, no OpenZeppelin Initializable, bridge authority as an immutable.
///     It stands in for the exact prior implementation in the upgrade tests; the fork test runs
///     against the real bytecode.

interface ILegacyERC20Bridged is IERC20 {
    function bridge() external view returns (address);
    function bridgeMint(address account_, uint256 amount_) external;
    function bridgeBurn(address account_, uint256 amount_) external;
}

contract LegacyERC20Core is IERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender_, uint256 amount_) external returns (bool) {
        _approve(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        _spendAllowance(from_, msg.sender, amount_);
        _transfer(from_, to_, amount_);
        return true;
    }

    function increaseAllowance(address spender_, uint256 addedValue_) external returns (bool) {
        _approve(msg.sender, spender_, allowance[msg.sender][spender_] + addedValue_);
        return true;
    }

    function decreaseAllowance(address spender_, uint256 subtractedValue_) external returns (bool) {
        uint256 currentAllowance = allowance[msg.sender][spender_];
        if (currentAllowance < subtractedValue_) {
            revert ErrorDecreasedAllowanceBelowZero();
        }
        unchecked {
            _approve(msg.sender, spender_, currentAllowance - subtractedValue_);
        }
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_)
        internal
        onlyNonZeroAccount(from_)
        onlyNonZeroAccount(to_)
    {
        _decreaseBalance(from_, amount_);
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }

    function _spendAllowance(address owner_, address spender_, uint256 amount_) internal {
        uint256 currentAllowance = allowance[owner_][spender_];
        if (currentAllowance == type(uint256).max) {
            return;
        }
        if (amount_ > currentAllowance) {
            revert ErrorNotEnoughAllowance();
        }
        unchecked {
            _approve(owner_, spender_, currentAllowance - amount_);
        }
    }

    function _approve(address owner_, address spender_, uint256 amount_)
        internal
        virtual
        onlyNonZeroAccount(owner_)
        onlyNonZeroAccount(spender_)
    {
        allowance[owner_][spender_] = amount_;
        emit Approval(owner_, spender_, amount_);
    }

    function _mint(address account_, uint256 amount_) internal onlyNonZeroAccount(account_) {
        totalSupply += amount_;
        balanceOf[account_] += amount_;
        emit Transfer(address(0), account_, amount_);
    }

    function _burn(address account_, uint256 amount_) internal onlyNonZeroAccount(account_) {
        _decreaseBalance(account_, amount_);
        totalSupply -= amount_;
        emit Transfer(account_, address(0), amount_);
    }

    function _decreaseBalance(address account_, uint256 amount_) internal {
        uint256 balance = balanceOf[account_];
        if (amount_ > balance) {
            revert ErrorNotEnoughBalance();
        }
        unchecked {
            balanceOf[account_] = balance - amount_;
        }
    }

    modifier onlyNonZeroAccount(address account_) {
        if (account_ == address(0)) {
            revert ErrorAccountIsZeroAddress();
        }
        _;
    }

    error ErrorNotEnoughBalance();
    error ErrorNotEnoughAllowance();
    error ErrorAccountIsZeroAddress();
    error ErrorDecreasedAllowanceBelowZero();
}

contract LegacyERC20Metadata {
    struct DynamicMetadata {
        string name;
        string symbol;
    }

    bytes32 private constant DYNAMIC_METADATA_SLOT = keccak256("ERC20Metdata.dynamicMetadata");

    uint8 public immutable decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        decimals = decimals_;
        _setERC20MetadataName(name_);
        _setERC20MetadataSymbol(symbol_);
    }

    function name() public view returns (string memory) {
        return _loadDynamicMetadata().name;
    }

    function symbol() public view returns (string memory) {
        return _loadDynamicMetadata().symbol;
    }

    function _setERC20MetadataName(string memory name_) internal {
        if (bytes(name()).length > 0) {
            revert ErrorNameAlreadySet();
        }
        _loadDynamicMetadata().name = name_;
    }

    function _setERC20MetadataSymbol(string memory symbol_) internal {
        if (bytes(symbol()).length > 0) {
            revert ErrorSymbolAlreadySet();
        }
        _loadDynamicMetadata().symbol = symbol_;
    }

    function _loadDynamicMetadata() private pure returns (DynamicMetadata storage r) {
        bytes32 slot = DYNAMIC_METADATA_SLOT;
        assembly {
            r.slot := slot
        }
    }

    error ErrorNameAlreadySet();
    error ErrorSymbolAlreadySet();
}

contract LegacyERC20Bridged is ILegacyERC20Bridged, LegacyERC20Core, LegacyERC20Metadata {
    address public immutable bridge;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address bridge_)
        LegacyERC20Metadata(name_, symbol_, decimals_)
    {
        bridge = bridge_;
    }

    function initialize(string memory name_, string memory symbol_) external {
        _setERC20MetadataName(name_);
        _setERC20MetadataSymbol(symbol_);
    }

    function bridgeMint(address account_, uint256 amount_) external onlyBridge {
        _mint(account_, amount_);
    }

    function bridgeBurn(address account_, uint256 amount_) external onlyBridge {
        _burn(account_, amount_);
    }

    modifier onlyBridge() {
        if (msg.sender != bridge) {
            revert ErrorNotBridge();
        }
        _;
    }

    error ErrorNotBridge();
}
