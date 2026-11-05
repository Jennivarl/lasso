// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice The two messages that cross between chains, hashed the same way on both sides.
library Commitments {
    bytes32 internal constant DEPOSIT_TAG = keccak256("COURTHOUSE_DEPOSIT_V1");
    bytes32 internal constant RULING_TAG = keccak256("COURTHOUSE_RULING_V1");

    /// @notice One line of a ruling: who receives how much collateral (in wei).
    struct Payout {
        address to;
        uint256 amount;
    }

    /// @notice What the vault stores when collateral is locked.
    function deposit(
        uint256 vaultChainId,
        address vault,
        uint256 depositId,
        address depositor,
        uint256 amount,
        uint256 courthouseChainId,
        address courthouse,
        uint256 loanId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEPOSIT_TAG, vaultChainId, vault, depositId, depositor, amount, courthouseChainId, courthouse, loanId
            )
        );
    }

    /// @notice What the Courthouse stores when it rules on a loan.
    function ruling(
        uint256 courthouseChainId,
        address courthouse,
        uint256 loanId,
        uint256 vaultChainId,
        address vault,
        uint256 depositId,
        Payout[] memory payouts
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(RULING_TAG, courthouseChainId, courthouse, loanId, vaultChainId, vault, depositId, payouts)
        );
    }
}
