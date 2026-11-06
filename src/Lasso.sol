// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Commitments} from "./libraries/Commitments.sol";

/// @title Lasso
/// @notice Lives on Portaldot. A loan paid out in native POT, backed by ETH locked on Ethereum.
///         If the borrower stops paying, a lender files a claim, the borrower can answer, an arbiter
///         panel decides, and the ruling says who gets the ETH: senior lender first, then junior,
///         then anything left back to the borrower. LassoVault on Ethereum carries the ruling out.
/// @dev Built for Portaldot's storage deposits (0.06 POT per byte of code, ~4 POT per new storage
///      slot): one small contract, native POT instead of a token, one senior and one junior lender
///      per loan, a whole loan packed into 8 storage slots, and state read from events.
///
///      Open -> (collateral proven + both tranches funded + drawdown) -> Active -> Repaid
///      Active -> claim -> InClaim -> (no answer) -> Defaulted
///      InClaim -> answer -> Disputed -> 2 of 3 arbiters -> Defaulted | Repaid (paid off-chain)
///      Open -> Cancelled
contract Lasso {
    enum Status {
        None,
        Open,
        Active,
        InClaim,
        Disputed,
        Repaid,
        Defaulted,
        Cancelled
    }

    struct Loan {
        // slot 0
        address borrower;
        Status status;
        uint8 flags;
        uint8 votesDefault;
        uint8 votesPaid;
        uint64 fundBy;
        // slot 1
        address vault;
        uint64 dueAt;
        uint16 seniorBps;
        uint16 juniorBps;
        // slot 2
        address senior;
        uint64 deadline; // answer deadline, then vote deadline
        // slot 3
        address junior;
        uint64 depositId;
        // slot 4
        address claimant;
        uint64 vaultChainId;
        // slot 5
        uint128 seniorAmount;
        uint128 juniorAmount;
        // slot 6
        uint128 collateral; // wei on the vault chain
        uint128 price; // POT (18-decimal EVM units) per 1e18 wei of collateral, agreed for settlement
        // slot 7
        uint128 repaid;
    }

    uint8 private constant FUNDED_SENIOR = 1;
    uint8 private constant FUNDED_JUNIOR = 2;
    uint8 private constant PROVEN = 4;
    uint8 private constant VOTED_0 = 32; // VOTED_0 << i for arbiter i

    bytes32 private constant ROAD_IN_TAG = keccak256("LASSO_ATTESTED_ROAD_IN_V1");

    /// @notice TEMPORARY trusted road: this key vouches that collateral is locked on Ethereum.
    ///         The ZK road replaces this check.
    address public immutable attester;
    address private immutable arbiter0;
    address private immutable arbiter1;
    address private immutable arbiter2;
    uint64 private immutable grace;
    uint64 private immutable window; // to answer a claim, and again to vote
    uint128 private immutable bond;

    uint256 public loanCount;
    mapping(uint256 => Loan) private loans;
    /// @notice The ruling Road Out carries to Ethereum. Plain mapping: the ZK road proves this slot.
    mapping(uint256 => bytes32) public rulingOf;

    /// @dev One event for every step, so an app can rebuild each loan from logs alone.
    event Step(uint256 indexed loanId, Status status, address indexed by, uint256 amount, bytes32 data);
    event Ruled(uint256 indexed loanId, bytes32 commitment, Commitments.Payouts payouts);

    constructor(address attester_, address[3] memory arbiters, uint64 grace_, uint64 window_, uint128 bond_) {
        attester = attester_;
        arbiter0 = arbiters[0];
        arbiter1 = arbiters[1];
        arbiter2 = arbiters[2];
        grace = grace_;
        window = window_;
        bond = bond_;
    }

    /// @notice Ask for a loan. Terms are packed into three words to keep this contract small:
    ///         amounts  = seniorAmount << 128 | juniorAmount
    ///         backing  = collateral << 128 | price
    ///         schedule = vaultChainId << 192 | fundBy << 128 | dueAt << 64 | seniorBps << 16 | juniorBps
    function request(address vault, uint256 amounts, uint256 backing, uint256 schedule) external returns (uint256 id) {
        uint64 fundBy = uint64(schedule >> 128);
        uint64 dueAt = uint64(schedule >> 64);
        if (uint128(backing >> 128) == 0 || uint128(backing) == 0 || fundBy <= block.timestamp || dueAt <= fundBy) {
            revert();
        }
        id = loanCount++;
        Loan storage l = loans[id];
        l.borrower = msg.sender;
        l.status = Status.Open;
        l.fundBy = fundBy;
        // Whole slots written at once: vault | dueAt | seniorBps | juniorBps, then the 128-bit pairs.
        l.vault = vault;
        l.dueAt = dueAt;
        l.seniorBps = uint16(schedule >> 16);
        l.juniorBps = uint16(schedule);
        l.vaultChainId = uint64(schedule >> 192);
        assembly {
            // slot 5 = seniorAmount | juniorAmount, slot 6 = collateral | price, low half first
            sstore(add(l.slot, 5), or(shr(128, amounts), shl(128, amounts)))
            sstore(add(l.slot, 6), or(shr(128, backing), shl(128, backing)))
        }
        _log(id, Status.Open, amounts, bytes32(backing));
    }

    /// @notice Prove the borrower locked the agreed ETH in the vault for this loan.
    function prove(uint256 id, uint64 depositId, bytes calldata sig) external {
        Loan storage l = _at(id, Status.Open);
        bytes32 c = Commitments.deposit(
            l.vaultChainId, l.vault, depositId, l.borrower, l.collateral, block.chainid, address(this), id
        );
        bytes32 digest =
            keccak256(abi.encode(ROAD_IN_TAG, block.chainid, address(this), l.vaultChainId, l.vault, depositId, c));
        // A malleated copy of a valid signature vouches for the same fact, so no s-range check is needed.
        address signer = ecrecover(
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)),
            uint8(sig[64]),
            bytes32(sig[0:32]),
            bytes32(sig[32:64])
        );
        if (signer == address(0) || signer != attester) revert();
        l.depositId = depositId;
        l.flags |= PROVEN;
        _log(id, Status.Open, depositId, c);
    }

    /// @notice Fund a whole tranche in one go, with exactly its amount in POT. When the last tranche
    ///         is funded, the loan starts and the principal goes straight to the borrower.
    function fund(uint256 id, bool senior) external payable {
        Loan storage l = _at(id, Status.Open);
        uint8 bit = senior ? FUNDED_SENIOR : FUNDED_JUNIOR;
        if (l.flags & PROVEN == 0 || l.flags & bit != 0 || block.timestamp > l.fundBy) revert();
        if (msg.sender == l.borrower || msg.value != (senior ? l.seniorAmount : l.juniorAmount)) revert();
        if (senior) l.senior = msg.sender;
        else l.junior = msg.sender;
        uint8 f = l.flags | bit;
        l.flags = f;
        _log(id, Status.Open, msg.value, senior ? bytes32("senior") : bytes32("junior"));
        if ((l.seniorAmount == 0 || f & FUNDED_SENIOR != 0) && (l.juniorAmount == 0 || f & FUNDED_JUNIOR != 0)) {
            l.status = Status.Active;
            uint256 principal = uint256(l.seniorAmount) + l.juniorAmount;
            _send(l.borrower, principal);
            _log(id, Status.Active, principal, 0);
        }
    }

    /// @notice Borrower walks away before the loan starts, or anyone once funding time is over.
    function cancel(uint256 id) external {
        Loan storage l = _at(id, Status.Open);
        if (msg.sender != l.borrower && block.timestamp <= l.fundBy) revert();
        l.status = Status.Cancelled;
        _log(id, Status.Cancelled, 0, 0);
        if (l.flags & PROVEN != 0) _release(id);
        // Refund whoever funded.
        if (l.senior != address(0)) l.senior.call{value: l.seniorAmount}("");
        if (l.junior != address(0)) l.junior.call{value: l.juniorAmount}("");
    }

    function repay(uint256 id) external payable {
        Loan storage l = loans[id];
        Status s = l.status;
        if (s != Status.Active && s != Status.InClaim && s != Status.Disputed) revert();
        uint256 before = l.repaid;
        uint256 total = before + msg.value;
        uint256 sOwed = _owed(l.seniorAmount, l.seniorBps);
        uint256 owed = sOwed + _owed(l.juniorAmount, l.juniorBps);
        if (msg.value == 0 || total > owed) revert();
        l.repaid = uint128(total);
        _log(id, s, msg.value, bytes32(total));
        // Lenders are paid as money arrives: senior until fully paid, then junior. A lender whose
        // address refuses the payment loses it; they cannot block the borrower from repaying.
        uint256 toSenior = _min(total, sOwed) - _min(before, sOwed);
        l.senior.call{value: toSenior}("");
        l.junior.call{value: msg.value - toSenior}("");
        if (total == owed) {
            // Paying in full closes any claim; bonds go back.
            l.status = Status.Repaid;
            _release(id);
            if (s != Status.Active) _send(l.claimant, bond);
            if (s == Status.Disputed) _send(l.borrower, bond);
        }
    }

    /// @notice A lender says the borrower defaulted. Only after the due date plus grace, with a bond.
    function claim(uint256 id, bytes32 evidence) external payable {
        Loan storage l = _at(id, Status.Active);
        if (block.timestamp <= uint256(l.dueAt) + grace) revert();
        if ((msg.sender != l.senior && msg.sender != l.junior) || msg.value != bond) revert();
        l.status = Status.InClaim;
        l.claimant = msg.sender;
        l.deadline = uint64(block.timestamp) + window;
        _log(id, Status.InClaim, msg.value, evidence);
    }

    /// @notice The borrower disputes, e.g. "I paid by bank transfer", posting the same bond.
    function answer(uint256 id, bytes32 evidence) external payable {
        Loan storage l = _at(id, Status.InClaim);
        if (msg.sender != l.borrower || msg.value != bond || block.timestamp > l.deadline) revert();
        l.status = Status.Disputed;
        l.deadline = uint64(block.timestamp) + window;
        _log(id, Status.Disputed, msg.value, evidence);
    }

    /// @notice A deadline passed. No answer to a claim: the default stands and the claimant gets the
    ///         bond back. No 2 matching votes in time: the borrower missed the due date, so the burden
    ///         of proof is on them, and the default stands.
    function finalize(uint256 id) external {
        Loan storage l = loans[id];
        Status s = l.status;
        if ((s != Status.InClaim && s != Status.Disputed) || block.timestamp <= l.deadline) revert();
        _default(id);
        _send(l.claimant, s == Status.InClaim ? bond : 2 * uint256(bond));
    }

    /// @notice An arbiter votes: did the borrower default (true) or pay (false)? 2 of 3 decides.
    function vote(uint256 id, bool isDefault) external {
        Loan storage l = _at(id, Status.Disputed);
        uint8 bit = msg.sender == arbiter0
            ? VOTED_0
            : msg.sender == arbiter1 ? VOTED_0 << 1 : msg.sender == arbiter2 ? VOTED_0 << 2 : 0;
        if (bit == 0 || l.flags & bit != 0 || block.timestamp > l.deadline) revert();
        l.flags |= bit;
        if (isDefault) l.votesDefault++;
        else l.votesPaid++;
        _log(id, Status.Disputed, isDefault ? 1 : 0, 0);
        if (l.votesDefault == 2 || l.votesPaid == 2) _settle(id, l.votesDefault == 2);
    }

    // ------------------------------------------------------------ rulings

    function _settle(uint256 id, bool isDefault) private {
        Loan storage l = loans[id];
        if (isDefault) {
            _default(id);
            _send(l.claimant, 2 * uint256(bond)); // the claim was right
        } else {
            l.status = Status.Repaid;
            _release(id);
            _send(l.borrower, 2 * uint256(bond)); // the borrower proved they paid off-chain
        }
    }

    function _release(uint256 id) private {
        Commitments.Payouts memory p;
        p.to[2] = loans[id].borrower;
        p.amount[2] = loans[id].collateral;
        _record(id, p);
    }

    /// @dev What is still owed comes out of the collateral: senior first, then junior, rest to the borrower.
    function _default(uint256 id) private {
        Loan storage l = loans[id];
        l.status = Status.Defaulted;
        uint256 sOwed = _owed(l.seniorAmount, l.seniorBps);
        uint256 sPaid = _min(l.repaid, sOwed);
        uint256 jShort = _owed(l.juniorAmount, l.juniorBps) - _min(l.repaid - sPaid, _owed(l.juniorAmount, l.juniorBps));

        Commitments.Payouts memory p;
        uint256 left = l.collateral;
        p.amount[0] = _min(left, _ceilDiv((sOwed - sPaid) * 1e18, l.price));
        left -= p.amount[0];
        p.amount[1] = _min(left, _ceilDiv(jShort * 1e18, l.price));
        p.amount[2] = left - p.amount[1];
        if (p.amount[0] != 0) p.to[0] = l.senior;
        if (p.amount[1] != 0) p.to[1] = l.junior;
        if (p.amount[2] != 0) p.to[2] = l.borrower;
        _record(id, p);
    }

    function _record(uint256 id, Commitments.Payouts memory p) private {
        Loan storage l = loans[id];
        bytes32 c = Commitments.ruling(block.chainid, address(this), id, l.vaultChainId, l.vault, l.depositId, p);
        rulingOf[id] = c;
        emit Ruled(id, c, p);
    }

    // ------------------------------------------------------------ helpers

    function _log(uint256 id, Status status, uint256 amount, bytes32 data) private {
        emit Step(id, status, msg.sender, amount, data);
    }

    function _at(uint256 id, Status want) private view returns (Loan storage l) {
        l = loans[id];
        if (l.status != want) revert();
    }

    function _owed(uint128 amount, uint16 bps) private pure returns (uint256) {
        return uint256(amount) * (10_000 + bps) / 10_000;
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
