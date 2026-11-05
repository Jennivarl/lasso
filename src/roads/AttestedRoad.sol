// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IRoadIn, IRoadOut} from "../interfaces/IRoads.sol";

/// @title AttestedRoad (TEMPORARY, TRUSTED)
/// @notice Stand-in for the ZK roads while they are being built. One attester key signs
///         "this commitment exists on the other chain". Whoever holds that key is trusted.
///         It exists so the Courthouse and the vault can be built and tested end to end now;
///         ZkRoadIn and ZkRoadOut replace it, and nothing else changes.
contract AttestedRoad is IRoadIn, IRoadOut {
    bytes32 public constant ROAD_IN_TAG = keccak256("COURTHOUSE_ATTESTED_ROAD_IN_V1");
    bytes32 public constant ROAD_OUT_TAG = keccak256("COURTHOUSE_ATTESTED_ROAD_OUT_V1");

    /// @dev secp256k1 order / 2, to reject malleable signatures.
    uint256 private constant HALF_N = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable attester;

    constructor(address attester_) {
        attester = attester_;
    }

    function verifyDeposit(
        uint256 vaultChainId,
        address vault,
        uint256 depositId,
        bytes32 commitment,
        bytes calldata proof
    ) external view returns (bool) {
        return _signedByAttester(depositDigest(vaultChainId, vault, depositId, commitment), proof);
    }

    function verifyRuling(
        uint256 courthouseChainId,
        address courthouse,
        uint256 loanId,
        bytes32 commitment,
        bytes calldata proof
    ) external view returns (bool) {
        return _signedByAttester(rulingDigest(courthouseChainId, courthouse, loanId, commitment), proof);
    }

    /// @notice What the attester signs for Road In. Bound to this road and this chain, so it cannot be replayed.
    function depositDigest(uint256 vaultChainId, address vault, uint256 depositId, bytes32 commitment)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(ROAD_IN_TAG, block.chainid, address(this), vaultChainId, vault, depositId, commitment)
        );
    }

    /// @notice What the attester signs for Road Out.
    function rulingDigest(uint256 courthouseChainId, address courthouse, uint256 loanId, bytes32 commitment)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(ROAD_OUT_TAG, block.chainid, address(this), courthouseChainId, courthouse, loanId, commitment)
        );
    }

    /// @dev proof = 65-byte signature (r, s, v) over the EIP-191 hash of `digest`.
    function _signedByAttester(bytes32 digest, bytes calldata sig) private view returns (bool) {
        if (sig.length != 65) return false;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > HALF_N || (v != 27 && v != 28)) return false;
        bytes32 h = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        address signer = ecrecover(h, v, r, s);
        return signer != address(0) && signer == attester;
    }
}
