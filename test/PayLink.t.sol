// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PayLink} from "../src/PayLink.sol";

contract MockEIP3009Token {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    string public name;
    string public constant version = "2";
    string public symbol;
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    error AuthorizationUsed();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error CallerMustBePayee();
    error InvalidSignature();
    error InsufficientBalance();

    constructor(string memory tokenName, string memory tokenSymbol) {
        name = tokenName;
        symbol = tokenSymbol;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, address(this))
        );
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

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
    ) external {
        if (msg.sender != to) revert CallerMustBePayee();
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();

        bytes32 structHash = keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
        if (ecrecover(digest, v, r, s) != from) revert InvalidSignature();

        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract PayLinkTest is Test {
    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    event Paid(
        bytes32 indexed id, address indexed payer, address indexed recipient, address token, uint256 amount, string ref
    );

    PayLink private link;
    MockEIP3009Token private usdc;
    MockEIP3009Token private eurc;
    uint256 private payerKey = 0xA11CE;
    uint256 private secondPayerKey = 0xCAFE;
    address private payer;
    address private secondPayer;
    address private recipient = address(0xB0B);

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(10);
        payer = vm.addr(payerKey);
        secondPayer = vm.addr(secondPayerKey);
        usdc = new MockEIP3009Token("USDC", "USDC");
        eurc = new MockEIP3009Token("EURC", "EURC");
        link = new PayLink(address(usdc), address(eurc));
        usdc.mint(payer, 1_000_000_000);
        eurc.mint(payer, 1_000_000_000);
        usdc.mint(secondPayer, 1_000_000_000);
    }

    function test_USDCHappyPathBalancesEventAndPaidBlock() public {
        bytes32 id = keccak256("invoice-1");
        uint256 amount = 12_500_000;
        string memory ref = "INV-2026-001";
        assertEq(link.paidBlock(id, address(usdc), recipient, amount, ref), 0);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(usdc, payerKey, id, recipient, amount, ref, 0, block.timestamp + 1 hours);

        vm.expectEmit(true, true, true, true, address(link));
        emit Paid(id, payer, recipient, address(usdc), amount, ref);
        link.payWithAuthorization(
            id, address(usdc), payer, recipient, amount, ref, 0, block.timestamp + 1 hours, v, r, s
        );

        assertEq(usdc.balanceOf(payer), 1_000_000_000 - amount);
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(link)), 0);
        assertEq(link.paidBlock(id, address(usdc), recipient, amount, ref), block.number);
    }

    function test_EURCPayment() public {
        _pay(eurc, payerKey, keccak256("euro-invoice"), recipient, 99_000_001, "EUR-7");
        assertEq(eurc.balanceOf(recipient), 99_000_001);
        assertEq(eurc.balanceOf(address(link)), 0);
    }

    function test_WrongSignerReverts() public {
        bytes32 id = keccak256("wrong-signer");
        uint256 before = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, secondPayerKey, id, recipient, 1, "", 0, before);
        vm.expectRevert(MockEIP3009Token.InvalidSignature.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 1, "", 0, before, v, r, s);
    }

    function test_ExpiredAuthorizationReverts() public {
        bytes32 id = keccak256("expired");
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 1, "", 0, block.timestamp);
        vm.expectRevert(MockEIP3009Token.AuthorizationExpired.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 1, "", 0, block.timestamp, v, r, s);
    }

    function test_NotYetValidAuthorizationReverts() public {
        bytes32 id = keccak256("early");
        uint256 afterTime = block.timestamp;
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 1, "", afterTime, beforeTime);
        vm.expectRevert(MockEIP3009Token.AuthorizationNotYetValid.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 1, "", afterTime, beforeTime, v, r, s);
    }

    function test_SamePayerCannotPaySameRequestTwice() public {
        bytes32 id = keccak256("once");
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 5_000_000, "A", 0, beforeTime);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 5_000_000, "A", 0, beforeTime, v, r, s);
        vm.expectRevert(MockEIP3009Token.AuthorizationUsed.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 5_000_000, "A", 0, beforeTime, v, r, s);
    }

    function test_SecondPayerCanPayAndFirstBlockIsKept() public {
        bytes32 id = keccak256("two-payers");
        _pay(usdc, payerKey, id, recipient, 7_000_000, "B");
        uint256 firstBlock = vm.getBlockNumber();
        vm.roll(25);
        _pay(usdc, secondPayerKey, id, recipient, 7_000_000, "B");
        assertEq(usdc.balanceOf(recipient), 14_000_000);
        assertEq(link.paidBlock(id, address(usdc), recipient, 7_000_000, "B"), firstBlock);
    }

    function test_UnknownTokenReverts() public {
        vm.expectRevert(PayLink.UnknownToken.selector);
        link.payWithAuthorization(bytes32(0), address(0xBAD), payer, recipient, 1, "", 0, 1, 0, 0, 0);
    }

    function test_ZeroTokenConfigurationReverts() public {
        vm.expectRevert(PayLink.ZeroToken.selector);
        new PayLink(address(0), address(eurc));
    }

    function test_ZeroAmountReverts() public {
        vm.expectRevert(PayLink.ZeroAmount.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, recipient, 0, "", 0, 1, 0, 0, 0);
    }

    function test_ZeroRecipientReverts() public {
        vm.expectRevert(PayLink.ZeroRecipient.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, address(0), 1, "", 0, 1, 0, 0, 0);
    }

    function test_LongRefReverts() public {
        vm.expectRevert(PayLink.RefTooLong.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, recipient, 1, string(new bytes(141)), 0, 1, 0, 0, 0);
    }

    function testFuzz_ExactAmountsAreForwarded(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000_000);
        usdc.mint(payer, amount);
        _pay(usdc, payerKey, keccak256(abi.encode(amount)), recipient, amount, "fuzz");
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(link)), 0);
    }

    function _pay(MockEIP3009Token token, uint256 privateKey, bytes32 id, address to, uint256 amount, string memory ref)
        private
    {
        uint256 beforeTime = block.timestamp + 1 hours;
        address from = vm.addr(privateKey);
        (uint8 v, bytes32 r, bytes32 s) = _sign(token, privateKey, id, to, amount, ref, 0, beforeTime);
        link.payWithAuthorization(id, address(token), from, to, amount, ref, 0, beforeTime, v, r, s);
    }

    function _sign(
        MockEIP3009Token token,
        uint256 privateKey,
        bytes32 id,
        address to,
        uint256 amount,
        string memory ref,
        uint256 validAfter,
        uint256 validBefore
    ) private view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 nonce = keccak256(abi.encode(id, address(token), to, amount, ref));
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, vm.addr(privateKey), address(link), amount, validAfter, validBefore, nonce)
        );
        return vm.sign(privateKey, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }
}
