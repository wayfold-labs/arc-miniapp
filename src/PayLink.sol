// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFiatToken {
    function transfer(address to, uint256 value) external returns (bool);

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title PayLink: one-transaction EURC and USDC payment requests on Arc
/// @notice Pulls an exact, wallet-authorized payment and forwards it immediately. The request lives
///         in the link; only the block of its first payment is retained by this contract.
/// @dev Compatible with Circle FiatToken v2 EIP-3009 receiveWithAuthorization implementations.
contract PayLink {
    uint256 public constant MAX_REF_BYTES = 140;

    /// @notice The only accepted USDC token.
    address public immutable USDC;
    /// @notice The only accepted EURC token.
    address public immutable EURC;

    /// keccak256(abi.encode(id, token, recipient, amount, ref)) => first paid block
    mapping(bytes32 requestKey => uint256 blockNumber) private _paidBlock;

    event Paid(
        bytes32 indexed id, address indexed payer, address indexed recipient, address token, uint256 amount, string ref
    );

    error UnknownToken();
    error ZeroToken();
    error ZeroRecipient();
    error ZeroAmount();
    error RefTooLong();
    error TokenTransferFailed();

    /// @param usdc Arc's USDC ERC-20 interface address.
    /// @param eurc Arc's EURC token address.
    constructor(address usdc, address eurc) {
        if (usdc == address(0) || eurc == address(0)) revert ZeroToken();
        USDC = usdc;
        EURC = eurc;
    }

    /// @notice Pays a request with an EIP-3009 authorization and forwards the tokens atomically.
    /// @param id Random request identifier carried in the payment link.
    /// @param token USDC or EURC, as configured at deployment.
    /// @param payer Wallet that signed the authorization and supplies the tokens.
    /// @param recipient Address that receives the full amount.
    /// @param amount Token amount in 6-decimal base units.
    /// @param ref Invoice number or other reference, at most 140 UTF-8 bytes.
    /// @param validAfter Authorization is valid strictly after this Unix timestamp.
    /// @param validBefore Authorization is valid strictly before this Unix timestamp.
    function payWithAuthorization(
        bytes32 id,
        address token,
        address payer,
        address recipient,
        uint256 amount,
        string calldata ref,
        uint256 validAfter,
        uint256 validBefore,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (token != USDC && token != EURC) revert UnknownToken();
        if (recipient == address(0)) revert ZeroRecipient();
        if (amount == 0) revert ZeroAmount();
        if (bytes(ref).length > MAX_REF_BYTES) revert RefTooLong();

        bytes32 key = _requestKey(id, token, recipient, amount, ref);
        IFiatToken(token).receiveWithAuthorization(payer, address(this), amount, validAfter, validBefore, key, v, r, s);
        _safeTransfer(token, recipient, amount);

        if (_paidBlock[key] == 0) _paidBlock[key] = block.number;
        // The only possible external callers above are the two immutable Circle token contracts.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Paid(id, payer, recipient, token, amount, ref);
    }

    /// @notice Returns the first block in which this exact request was paid, or zero if unpaid.
    function paidBlock(bytes32 id, address token, address recipient, uint256 amount, string calldata ref)
        external
        view
        returns (uint256)
    {
        return _paidBlock[_requestKey(id, token, recipient, amount, ref)];
    }

    function _requestKey(bytes32 id, address token, address recipient, uint256 amount, string calldata ref)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(id, token, recipient, amount, ref));
    }

    function _safeTransfer(address token, address recipient, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IFiatToken.transfer, (recipient, amount)));
        if (!ok || (result.length != 0 && result.length != 32)) revert TokenTransferFailed();
        if (result.length == 32) {
            uint256 returned;
            assembly ("memory-safe") {
                returned := mload(add(result, 32))
            }
            if (returned != 1) revert TokenTransferFailed();
        }
    }
}
