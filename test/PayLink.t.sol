// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PayLink} from "../src/PayLink.sol";

contract Rejecter {
    receive() external payable { revert("no"); }
}

contract PayLinkTest is Test {
    event Paid(bytes32 indexed id, address indexed payer, address indexed recipient, uint256 amount, string memo);

    PayLink link;
    address payer = address(0xA11CE);
    address payable recipient = payable(address(0xB0B));

    function setUp() public {
        link = new PayLink();
        vm.deal(payer, 1_000 ether);
    }

    function test_forwardsValueAndEmits() public {
        bytes32 id = keccak256("invoice-1");
        vm.expectEmit(true, true, true, true, address(link));
        emit Paid(id, payer, recipient, 12.5 ether, "INV-2026-001");
        vm.prank(payer);
        link.pay{value: 12.5 ether}(id, recipient, "INV-2026-001");
        assertEq(recipient.balance, 12.5 ether);
        assertEq(address(link).balance, 0);
    }

    function testFuzz_forwardsExactAmount(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(payer, amount);
        vm.prank(payer);
        link.pay{value: amount}(bytes32(uint256(1)), recipient, "");
        assertEq(recipient.balance, amount);
        assertEq(address(link).balance, 0);
    }

    function test_revertsOnZeroRecipient() public {
        vm.prank(payer);
        vm.expectRevert(PayLink.ZeroRecipient.selector);
        link.pay{value: 1 ether}(bytes32(0), payable(address(0)), "");
    }

    function test_revertsOnZeroAmount() public {
        vm.prank(payer);
        vm.expectRevert(PayLink.ZeroAmount.selector);
        link.pay(bytes32(0), recipient, "");
    }

    function test_revertsOnLongMemo() public {
        string memory memo = string(new bytes(141));
        vm.prank(payer);
        vm.expectRevert(PayLink.MemoTooLong.selector);
        link.pay{value: 1 ether}(bytes32(0), recipient, memo);
    }

    function test_revertsWhenRecipientRejects() public {
        Rejecter r = new Rejecter();
        vm.prank(payer);
        vm.expectRevert(PayLink.TransferFailed.selector);
        link.pay{value: 1 ether}(bytes32(0), payable(address(r)), "");
        assertEq(payer.balance, 1_000 ether);
    }
}
