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
    uint8 public transferMode;

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

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferMode == 1) return false;
        if (transferMode == 2) revert("transfer reverted");
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
        bytes32 digest = _validate(from, to, value, validAfter, validBefore, nonce);
        if (from.code.length == 0) {
            if (ecrecover(digest, v, r, s) != from) revert InvalidSignature();
        } else if (IERC1271Wallet(from).isValidSignature(digest, abi.encodePacked(r, s, v)) != 0x1626ba7e) {
            revert InvalidSignature();
        }
        _receive(from, to, value, nonce);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        bytes32 digest = _validate(from, to, value, validAfter, validBefore, nonce);
        if (from.code.length == 0) {
            if (signature.length != 65) revert InvalidSignature();
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 32))
                v := byte(0, calldataload(add(signature.offset, 64)))
            }
            if (v != 27 && v != 28) revert InvalidSignature();
            if (ecrecover(digest, v, r, s) != from) revert InvalidSignature();
        } else if (IERC1271Wallet(from).isValidSignature(digest, signature) != 0x1626ba7e) {
            revert InvalidSignature();
        }
        _receive(from, to, value, nonce);
    }

    function _validate(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        private
        view
        returns (bytes32 digest)
    {
        if (msg.sender != to) revert CallerMustBePayee();
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();

        bytes32 structHash = keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _receive(address from, address to, uint256 value, bytes32 nonce) private {
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IERC1271Wallet {
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4);
}

contract Mock1271Wallet {
    bytes32 private _digest;
    bytes32 private _signatureHash;

    function approve(bytes32 digest, bytes memory signature) external {
        _digest = digest;
        _signatureHash = keccak256(signature);
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return digest == _digest && keccak256(signature) == _signatureHash ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
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
        vm.expectRevert(PayLink.AlreadyPaid.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 5_000_000, "A", 0, beforeTime, v, r, s);
    }

    function test_SecondPayerCannotPaySameRequest() public {
        bytes32 id = keccak256("two-payers");
        _pay(usdc, payerKey, id, recipient, 7_000_000, "B");
        uint256 firstBlock = vm.getBlockNumber();
        vm.roll(25);
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, secondPayerKey, id, recipient, 7_000_000, "B", 0, beforeTime);
        vm.expectRevert(PayLink.AlreadyPaid.selector);
        link.payWithAuthorization(id, address(usdc), secondPayer, recipient, 7_000_000, "B", 0, beforeTime, v, r, s);
        assertEq(usdc.balanceOf(recipient), 7_000_000);
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

    function test_USDCWithoutCodeReverts() public {
        vm.expectRevert(PayLink.NoCode.selector);
        new PayLink(address(0xA11CE), address(eurc));
    }

    function test_EURCWithoutCodeReverts() public {
        vm.expectRevert(PayLink.NoCode.selector);
        new PayLink(address(usdc), address(0xE0C));
    }

    function test_ZeroAmountReverts() public {
        vm.expectRevert(PayLink.ZeroAmount.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, recipient, 0, "", 0, 1, 0, 0, 0);
    }

    function test_ZeroRecipientReverts() public {
        vm.expectRevert(PayLink.ZeroRecipient.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, address(0), 1, "", 0, 1, 0, 0, 0);
    }

    function test_InvalidRecipientPayLinkReverts() public {
        vm.expectRevert(PayLink.InvalidRecipient.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, address(link), 1, "", 0, 1, 0, 0, 0);
    }

    function test_InvalidRecipientUSDCReverts() public {
        vm.expectRevert(PayLink.InvalidRecipient.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, address(usdc), 1, "", 0, 1, 0, 0, 0);
    }

    function test_InvalidRecipientEURCReverts() public {
        vm.expectRevert(PayLink.InvalidRecipient.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, address(eurc), 1, "", 0, 1, 0, 0, 0);
    }

    function test_LongRefReverts() public {
        vm.expectRevert(PayLink.RefTooLong.selector);
        link.payWithAuthorization(bytes32(0), address(usdc), payer, recipient, 1, string(new bytes(141)), 0, 1, 0, 0, 0);
    }

    function test_140ByteRefAccepted() public {
        _pay(usdc, payerKey, keccak256("140 bytes"), recipient, 1, string(new bytes(140)));
    }

    function test_DirectReceiveByThirdPartyReverts() public {
        bytes32 id = keccak256("direct");
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 1, "", 0, beforeTime);
        bytes32 nonce = keccak256(abi.encode(id, address(usdc), recipient, 1, ""));
        vm.expectRevert(MockEIP3009Token.CallerMustBePayee.selector);
        usdc.receiveWithAuthorization(payer, address(link), 1, 0, beforeTime, nonce, v, r, s);
    }

    function test_TransferFalseRollsBackPaymentAndAuthorization() public {
        _assertTransferFailureRollsBack(1);
    }

    function test_TransferRevertRollsBackPaymentAndAuthorization() public {
        _assertTransferFailureRollsBack(2);
    }

    function test_ERC1271PayerPaysThroughBytesOverload() public {
        bytes32 id = keccak256("1271");
        uint256 amount = 3_000_000;
        uint256 beforeTime = block.timestamp + 1 hours;
        bytes memory signature = hex"deadbeef";
        Mock1271Wallet wallet = new Mock1271Wallet();
        usdc.mint(address(wallet), amount);
        bytes32 nonce = keccak256(abi.encode(id, address(usdc), recipient, amount, "smart"));
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, address(wallet), address(link), amount, 0, beforeTime, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        wallet.approve(digest, signature);

        link.payWithAuthorization(
            id, address(usdc), address(wallet), recipient, amount, "smart", 0, beforeTime, signature
        );
        assertEq(usdc.balanceOf(recipient), amount);
        assertTrue(usdc.authorizationState(address(wallet), nonce));
    }

    function test_ERC1271PayerPaysThroughVRSOverloadWith65ByteSignature() public {
        bytes32 id = keccak256("1271-vrs");
        uint256 amount = 4_000_000;
        uint256 beforeTime = block.timestamp + 1 hours;
        Mock1271Wallet wallet = new Mock1271Wallet();
        usdc.mint(address(wallet), amount);
        bytes32 nonce = keccak256(abi.encode(id, address(usdc), recipient, amount, "smart-vrs"));
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, address(wallet), address(link), amount, 0, beforeTime, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        uint8 v = 28;
        bytes32 r = keccak256("contract-r");
        bytes32 s = keccak256("contract-s");
        wallet.approve(digest, abi.encodePacked(r, s, v));

        link.payWithAuthorization(
            id, address(usdc), address(wallet), recipient, amount, "smart-vrs", 0, beforeTime, v, r, s
        );
        assertEq(usdc.balanceOf(recipient), amount);
        assertTrue(usdc.authorizationState(address(wallet), nonce));
    }

    function test_EOAPaysThroughBytesOverload() public {
        bytes32 id = keccak256("eoa-bytes");
        uint256 amount = 5_000_000;
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, amount, "eoa", 0, beforeTime);

        link.payWithAuthorization(
            id, address(usdc), payer, recipient, amount, "eoa", 0, beforeTime, abi.encodePacked(r, s, v)
        );
        assertEq(usdc.balanceOf(recipient), amount);
    }

    function test_EOABytesOverloadRejectsNonCanonicalV() public {
        bytes32 id = keccak256("eoa-bytes-v");
        uint256 beforeTime = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 1, "", 0, beforeTime);
        vm.expectRevert(MockEIP3009Token.InvalidSignature.selector);
        link.payWithAuthorization(
            id, address(usdc), payer, recipient, 1, "", 0, beforeTime, abi.encodePacked(r, s, uint8(0))
        );
    }

    function testFuzz_ChangedRequestFieldCannotReuseSignature(uint8 changedField) public {
        changedField = uint8(bound(changedField, 0, 4));
        bytes32 id = keccak256("bound-request");
        address token = address(usdc);
        address to = recipient;
        uint256 amount = 8_000_000;
        string memory ref = "INV-original";
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, to, amount, ref, 0, beforeTime);
        if (changedField == 0) id = keccak256("changed-id");
        else if (changedField == 1) token = address(eurc);
        else if (changedField == 2) to = address(0xD00D);
        else if (changedField == 3) amount++;
        else ref = "INV-changed";

        vm.expectRevert(MockEIP3009Token.InvalidSignature.selector);
        link.payWithAuthorization(id, token, payer, to, amount, ref, 0, beforeTime, v, r, s);
    }

    function test_RequestKeyKnownVector() public pure {
        bytes32 id = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
        address token = 0x2222222222222222222222222222222222222222;
        address to = 0x3333333333333333333333333333333333333333;
        bytes32 expected = 0x968673589daf1dd67c13c22673b29dac35f7f42cfb1bd35bf6523c7c1428e4dd;
        assertEq(keccak256(abi.encode(id, token, to, uint256(12_500_000), "INV-1")), expected);
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

    function _assertTransferFailureRollsBack(uint8 mode) private {
        bytes32 id = keccak256(abi.encode("transfer failure", mode));
        uint256 beforeTime = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(usdc, payerKey, id, recipient, 2, "rollback", 0, beforeTime);
        bytes32 nonce = keccak256(abi.encode(id, address(usdc), recipient, 2, "rollback"));
        usdc.setTransferMode(mode);
        vm.expectCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xef55bec6), payer, address(link), 2, 0, beforeTime, nonce, v, r, s)
        );
        vm.expectRevert(PayLink.TokenTransferFailed.selector);
        link.payWithAuthorization(id, address(usdc), payer, recipient, 2, "rollback", 0, beforeTime, v, r, s);
        assertEq(link.paidBlock(id, address(usdc), recipient, 2, "rollback"), 0);
        assertFalse(usdc.authorizationState(payer, nonce));
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
