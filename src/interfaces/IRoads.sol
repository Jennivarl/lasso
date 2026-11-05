// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Road In: lets Portaldot check a fact that happened on the collateral chain.
/// @dev The proof must show that `commitment` is stored at `commitments[depositId]`
///      in `vault` on chain `vaultChainId`, at a finalized block.
interface IRoadIn {
    function verifyDeposit(
        uint256 vaultChainId,
        address vault,
        uint256 depositId,
        bytes32 commitment,
        bytes calldata proof
    ) external view returns (bool);
}

/// @notice Road Out: lets the collateral chain check a ruling made on Portaldot.
/// @dev The proof must show that `commitment` is stored at `rulingOf[loanId]`
///      in `courthouse` on chain `courthouseChainId`, at a finalized block.
interface IRoadOut {
    function verifyRuling(
        uint256 courthouseChainId,
        address courthouse,
        uint256 loanId,
        bytes32 commitment,
        bytes calldata proof
    ) external view returns (bool);
}
