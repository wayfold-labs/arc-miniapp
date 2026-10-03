// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @dev Local-only Circle FiatToken v2-style mock used by e2e.sh.
contract MockFiatToken {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    string public constant name = "EURC";
    string public constant version = "2";
    string public constant symbol = "EURC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor() {
        balanceOf[msg.sender] = 1_000_000_000_000;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), block.chainid, address(this))
        );
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
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
            require(ecrecover(digest, v, r, s) == from, "bad signature");
        } else {
            require(
                IERC1271(from).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e,
                "bad contract signature"
            );
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
            require(signature.length == 65, "bad signature length");
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 32))
                v := byte(0, calldataload(add(signature.offset, 64)))
            }
            require(v == 27 || v == 28, "bad signature v");
            require(ecrecover(digest, v, r, s) == from, "bad signature");
        } else {
            require(IERC1271(from).isValidSignature(digest, signature) == 0x1626ba7e, "bad contract signature");
        }
        _receive(from, to, value, nonce);
    }

    function _validate(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        private
        view
        returns (bytes32)
    {
        require(msg.sender == to, "caller must be payee");
        require(block.timestamp > validAfter && block.timestamp < validBefore, "invalid time");
        require(!authorizationState[from][nonce], "authorization used");
        bytes32 structHash = keccak256(abi.encode(RECEIVE_TYPEHASH, from, to, value, validAfter, validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _receive(address from, address to, uint256 value, bytes32 nonce) private {
        authorizationState[from][nonce] = true;
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}
