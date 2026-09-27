// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title PayLink: one-transaction USDC payment requests on Arc
/// @notice On Arc, USDC is the native gas token (18 decimals). A payer sends the requested amount
///         as msg.value and pays gas in the same currency; this contract forwards the value to the
///         recipient and records the payment as an event keyed by the request id. It holds no funds
///         and keeps no state: the request itself lives in the link, and its status is read from logs.
contract PayLink {
    uint256 public constant MAX_MEMO_BYTES = 140;

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
        emit Paid(id, msg.sender, recipient, msg.value, memo);
        (bool ok,) = recipient.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }
}
