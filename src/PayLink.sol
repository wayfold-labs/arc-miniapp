// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title PayLink: one-transaction USDC payment requests on Arc
/// @notice On Arc, USDC is the native gas token (18 decimals). A payer sends the requested amount
///         as msg.value and pays gas in the same currency; this contract forwards the value to the
///         recipient, remembers the block of the first payment that matches the request exactly, and
///         emits an event with the details. It never holds funds. The request itself lives in the link.
contract PayLink {
    uint256 public constant MAX_MEMO_BYTES = 140;

    /// keccak256(abi.encode(id, recipient, amount, memo)) => block number of the first matching payment
    mapping(bytes32 => uint256) private _paidBlock;

    event Paid(bytes32 indexed id, address indexed payer, address indexed recipient, uint256 amount, string memo);

    error ZeroRecipient();
    error ZeroAmount();
    error MemoTooLong();
    error TransferFailed();

    /// @param id        request id chosen by whoever created the link (random 32 bytes)
    /// @param recipient address that receives the USDC
    /// @param memo      short reference shown to both sides, e.g. an invoice number
    function pay(bytes32 id, address payable recipient, string calldata memo) external payable {
        if (recipient == address(0)) revert ZeroRecipient();
        if (msg.value == 0) revert ZeroAmount();
        if (bytes(memo).length > MAX_MEMO_BYTES) revert MemoTooLong();
        bytes32 key = keccak256(abi.encode(id, recipient, msg.value, memo));
        if (_paidBlock[key] == 0) _paidBlock[key] = block.number;
        emit Paid(id, msg.sender, recipient, msg.value, memo);
        (bool ok,) = recipient.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Block of the first payment of exactly `amount` to `recipient` for request `id` with `memo`; 0 if unpaid.
    ///         Lets a client check a request with one call instead of scanning logs across a block range.
    function paidBlock(bytes32 id, address recipient, uint256 amount, string calldata memo) external view returns (uint256) {
        return _paidBlock[keccak256(abi.encode(id, recipient, amount, memo))];
    }
}
