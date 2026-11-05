// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRoadIn} from "./interfaces/IRoads.sol";
import {Commitments} from "./libraries/Commitments.sol";

/// @title Lasso
/// @notice Lives on Portaldot. Runs loans backed by collateral locked on another chain, and when a
///         borrower stops paying, runs a fair default process: claim, response, panel vote, ruling.
///         Every ruling is a list of who gets the collateral, paid senior lenders first.
/// @dev Life of a loan:
///      Open -> (collateral confirmed + fully funded + drawdown) -> Active -> Repaid
///      Active -> claim filed -> InClaim -> (no response) -> Defaulted
///      InClaim -> (borrower responds) -> Disputed -> panel vote -> Defaulted | Repaid (paid off-chain)
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

    enum Tranche {
        Senior,
        Junior
    }

    struct Terms {
        IERC20 asset; // what lenders lend and the borrower repays
        uint256 seniorTarget; // principal from senior lenders
        uint256 juniorTarget; // principal from junior lenders
        uint16 seniorRateBps; // flat interest for the whole term
        uint16 juniorRateBps;
        uint64 fundingDeadline;
        uint64 dueDate;
        uint256 vaultChainId; // where the collateral sits
        address vault;
        uint256 collateralAmount; // in wei on the vault chain
        uint256 settlementPrice; // asset units per 1e18 wei of collateral, agreed for settlement
    }

    struct Loan {
        address borrower;
        Status status;
        bool collateralConfirmed;
        uint256 depositId;
        uint256 seniorRaised;
        uint256 juniorRaised;
        uint256 repaid;
        // claim
        address claimant;
        uint64 responseDeadline;
        uint64 voteDeadline;
        bytes32 claimEvidence;
        bytes32 responseEvidence;
        uint16 votesDefault;
        uint16 votesPaid;
    }

    uint256 public constant MAX_LENDERS_PER_TRANCHE = 25;
    uint256 public constant BPS = 10_000;

    address public owner;
    IRoadIn public roadIn;

    uint64 public immutable gracePeriod;
    uint64 public immutable responseWindow;
    uint64 public immutable voteWindow;
    uint256 public immutable claimBond;

    // Arbiter panel. Temporary governance: the owner appoints arbiters.
    mapping(address => bool) public isArbiter;
    uint16 public arbiterCount;
    uint16 public quorum;

    uint256 public nextLoanId;
    mapping(uint256 => Terms) internal _terms;
    mapping(uint256 => Loan) internal _loans;
    mapping(uint256 => mapping(Tranche => address[])) internal _lenders;
    mapping(uint256 => mapping(Tranche => mapping(address => uint256))) public contribution;
    mapping(uint256 => mapping(address => bool)) public withdrawn;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Road Out proves this slot. Keep it a plain mapping so the storage slot is predictable.
    mapping(uint256 => bytes32) public rulingOf;
    mapping(uint256 => Commitments.Payout[]) internal _payouts;

    bool private _locked;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, Terms terms);
    event CollateralConfirmed(uint256 indexed loanId, uint256 depositId);
    event Funded(uint256 indexed loanId, address indexed lender, Tranche tranche, uint256 amount);
    event Drawdown(uint256 indexed loanId, uint256 amount);
    event Repayment(uint256 indexed loanId, uint256 amount, uint256 totalRepaid);
    event ClaimFiled(uint256 indexed loanId, address indexed claimant, bytes32 evidence, uint64 responseDeadline);
    event ClaimAnswered(uint256 indexed loanId, bytes32 evidence, uint64 voteDeadline);
    event Voted(uint256 indexed loanId, address indexed arbiter, bool isDefault);
    event Ruled(uint256 indexed loanId, Status outcome, bytes32 commitment, Commitments.Payout[] payouts);
    event Withdrawn(uint256 indexed loanId, address indexed lender, uint256 amount);
    event ArbiterSet(address indexed arbiter, bool active);
    event QuorumSet(uint16 quorum);
    event RoadInChanged(address road);

    error NotOwner();
    error NotBorrower();
    error NotLender();
    error NotArbiter();
    error WrongStatus(Status status);
    error BadTerms();
    error CollateralNotConfirmed();
    error CollateralAlreadyConfirmed();
    error CollateralNotProven();
    error CollateralMismatch();
    error FundingClosed();
    error OverTarget();
    error TooManyLenders();
    error NotFullyFunded();
    error TooEarly();
    error TooLate();
    error AlreadyVoted();
    error ConflictOfInterest();
    error NothingOwed();
    error AlreadyWithdrawn();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IRoadIn road, uint64 grace, uint64 respondWindow, uint64 voteWindow_, uint256 bond) {
        owner = msg.sender;
        roadIn = road;
        gracePeriod = grace;
        responseWindow = respondWindow;
        voteWindow = voteWindow_;
        claimBond = bond;
        emit RoadInChanged(address(road));
    }

    // ---------------------------------------------------------------- admin (temporary)

    /// @notice Temporary: lets the owner swap the test road for the ZK road.
    function setRoadIn(IRoadIn road) external onlyOwner {
        roadIn = road;
        emit RoadInChanged(address(road));
    }

    function setArbiter(address arbiter, bool active) external onlyOwner {
        if (isArbiter[arbiter] == active) return;
        isArbiter[arbiter] = active;
        if (active) arbiterCount++;
        else arbiterCount--;
        emit ArbiterSet(arbiter, active);
    }

    function setQuorum(uint16 q) external onlyOwner {
        quorum = q;
        emit QuorumSet(q);
    }

    // ---------------------------------------------------------------- loan setup

    function requestLoan(Terms calldata t) external returns (uint256 loanId) {
        if (
            address(t.asset) == address(0) || t.seniorTarget + t.juniorTarget == 0 || t.vault == address(0)
                || t.collateralAmount == 0 || t.settlementPrice == 0 || t.fundingDeadline <= block.timestamp
                || t.dueDate <= t.fundingDeadline
        ) revert BadTerms();

        loanId = nextLoanId++;
        _terms[loanId] = t;
        Loan storage l = _loans[loanId];
        l.borrower = msg.sender;
        l.status = Status.Open;
        emit LoanRequested(loanId, msg.sender, t);
    }

    /// @notice Prove, through Road In, that the borrower locked the agreed collateral for this loan.
    function confirmCollateral(uint256 loanId, uint256 depositId, uint256 amount, bytes calldata proof) external {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        if (l.status != Status.Open) revert WrongStatus(l.status);
        if (l.collateralConfirmed) revert CollateralAlreadyConfirmed();
        if (amount != t.collateralAmount) revert CollateralMismatch();

        bytes32 c = Commitments.deposit(
            t.vaultChainId, t.vault, depositId, l.borrower, amount, block.chainid, address(this), loanId
        );
        if (!roadIn.verifyDeposit(t.vaultChainId, t.vault, depositId, c, proof)) revert CollateralNotProven();

        l.collateralConfirmed = true;
        l.depositId = depositId;
        emit CollateralConfirmed(loanId, depositId);
    }

    /// @notice Lend into a tranche. Lenders only fund once the collateral is proven locked.
    function fund(uint256 loanId, Tranche tranche, uint256 amount) external nonReentrant {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        if (l.status != Status.Open) revert WrongStatus(l.status);
        if (!l.collateralConfirmed) revert CollateralNotConfirmed();
        if (block.timestamp > t.fundingDeadline) revert FundingClosed();
        if (msg.sender == l.borrower) revert ConflictOfInterest();

        uint256 target = tranche == Tranche.Senior ? t.seniorTarget : t.juniorTarget;
        uint256 raised = tranche == Tranche.Senior ? l.seniorRaised : l.juniorRaised;
        if (amount == 0 || raised + amount > target) revert OverTarget();

        if (contribution[loanId][tranche][msg.sender] == 0) {
            if (_lenders[loanId][tranche].length == MAX_LENDERS_PER_TRANCHE) revert TooManyLenders();
            _lenders[loanId][tranche].push(msg.sender);
        }
        contribution[loanId][tranche][msg.sender] += amount;
        if (tranche == Tranche.Senior) l.seniorRaised += amount;
        else l.juniorRaised += amount;

        _pull(t.asset, msg.sender, amount);
        emit Funded(loanId, msg.sender, tranche, amount);
    }

    /// @notice Borrower takes the money once both tranches are full.
    function drawdown(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (l.status != Status.Open) revert WrongStatus(l.status);
        if (l.seniorRaised != t.seniorTarget || l.juniorRaised != t.juniorTarget) revert NotFullyFunded();

        l.status = Status.Active;
        uint256 principal = t.seniorTarget + t.juniorTarget;
        _push(t.asset, l.borrower, principal);
        emit Drawdown(loanId, principal);
    }

    /// @notice Borrower walks away before drawdown, or anyone after the funding deadline passes.
    ///         Lenders get their money back and the collateral goes back to the borrower.
    function cancel(uint256 loanId) external {
        Loan storage l = _loans[loanId];
        if (l.status != Status.Open) revert WrongStatus(l.status);
        if (msg.sender != l.borrower && block.timestamp <= _terms[loanId].fundingDeadline) revert TooEarly();

        l.status = Status.Cancelled;
        if (l.collateralConfirmed) _ruleRelease(loanId);
        else emit Ruled(loanId, Status.Cancelled, bytes32(0), new Commitments.Payout[](0));
    }

    // ---------------------------------------------------------------- repayment

    function repay(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        Status s = l.status;
        if (s != Status.Active && s != Status.InClaim && s != Status.Disputed) revert WrongStatus(s);

        uint256 left = totalOwed(loanId) - l.repaid;
        if (left == 0) revert NothingOwed();
        if (amount > left) amount = left;

        l.repaid += amount;
        _pull(t.asset, msg.sender, amount);
        emit Repayment(loanId, amount, l.repaid);

        if (l.repaid == totalOwed(loanId)) {
            // Paying in full ends any open claim: everyone gets their bond back.
            if (s == Status.InClaim || s == Status.Disputed) {
                _push(t.asset, l.claimant, claimBond);
                if (s == Status.Disputed) _push(t.asset, l.borrower, claimBond);
            }
            l.status = Status.Repaid;
            _ruleRelease(loanId);
        }
    }

    // ---------------------------------------------------------------- default process

    /// @notice A lender says the borrower defaulted. Allowed only after the due date plus grace.
    ///         The lender posts a bond, lost if the claim is shown to be false.
    function fileClaim(uint256 loanId, bytes32 evidence) external nonReentrant {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        if (l.status != Status.Active) revert WrongStatus(l.status);
        if (block.timestamp <= uint256(t.dueDate) + gracePeriod) revert TooEarly();
        if (contribution[loanId][Tranche.Senior][msg.sender] + contribution[loanId][Tranche.Junior][msg.sender] == 0) {
            revert NotLender();
        }

        l.status = Status.InClaim;
        l.claimant = msg.sender;
        l.claimEvidence = evidence;
        l.responseDeadline = uint64(block.timestamp) + responseWindow;
        _pull(t.asset, msg.sender, claimBond);
        emit ClaimFiled(loanId, msg.sender, evidence, l.responseDeadline);
    }

    /// @notice The borrower disputes the claim, e.g. "I paid off-chain, here is the bank receipt".
    ///         They post the same bond. The arbiter panel then decides.
    function answerClaim(uint256 loanId, bytes32 evidence) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (msg.sender != l.borrower) revert NotBorrower();
        if (l.status != Status.InClaim) revert WrongStatus(l.status);
        if (block.timestamp > l.responseDeadline) revert TooLate();

        l.status = Status.Disputed;
        l.responseEvidence = evidence;
        l.voteDeadline = uint64(block.timestamp) + voteWindow;
        _pull(_terms[loanId].asset, msg.sender, claimBond);
        emit ClaimAnswered(loanId, evidence, l.voteDeadline);
    }

    /// @notice No answer in time: the default stands.
    function finalizeUnanswered(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != Status.InClaim) revert WrongStatus(l.status);
        if (block.timestamp <= l.responseDeadline) revert TooEarly();

        _push(_terms[loanId].asset, l.claimant, claimBond);
        _ruleDefault(loanId);
    }

    /// @notice An arbiter votes: did the borrower default (true) or did they pay (false)?
    function vote(uint256 loanId, bool isDefault) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (!isArbiter[msg.sender]) revert NotArbiter();
        if (l.status != Status.Disputed) revert WrongStatus(l.status);
        if (block.timestamp > l.voteDeadline) revert TooLate();
        if (hasVoted[loanId][msg.sender]) revert AlreadyVoted();
        if (
            msg.sender == l.borrower || contribution[loanId][Tranche.Senior][msg.sender] != 0
                || contribution[loanId][Tranche.Junior][msg.sender] != 0
        ) revert ConflictOfInterest();

        hasVoted[loanId][msg.sender] = true;
        if (isDefault) l.votesDefault++;
        else l.votesPaid++;
        emit Voted(loanId, msg.sender, isDefault);

        if (quorum != 0 && l.votesDefault >= quorum) _settleDispute(loanId, true);
        else if (quorum != 0 && l.votesPaid >= quorum) _settleDispute(loanId, false);
    }

    /// @notice Voting time ran out without a quorum. The borrower missed the due date, so the burden
    ///         of proof is on them: the default stands unless more arbiters said they paid.
    function resolveExpired(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != Status.Disputed) revert WrongStatus(l.status);
        if (block.timestamp <= l.voteDeadline) revert TooEarly();
        _settleDispute(loanId, l.votesPaid <= l.votesDefault);
    }

    // ---------------------------------------------------------------- lenders get paid

    /// @notice What a lender can take out of the asset pool, once the loan is over.
    function claimable(uint256 loanId, address lender) public view returns (uint256) {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        if (withdrawn[loanId][lender]) return 0;
        uint256 cs = contribution[loanId][Tranche.Senior][lender];
        uint256 cj = contribution[loanId][Tranche.Junior][lender];

        if (l.status == Status.Cancelled) return cs + cj;
        if (l.status != Status.Repaid && l.status != Status.Defaulted) return 0;

        (uint256 seniorPool, uint256 juniorPool) = _assetWaterfall(loanId);
        uint256 amount;
        if (cs != 0) amount += seniorPool * cs / t.seniorTarget;
        if (cj != 0) amount += juniorPool * cj / t.juniorTarget;
        return amount;
    }

    function withdraw(uint256 loanId) external nonReentrant {
        if (withdrawn[loanId][msg.sender]) revert AlreadyWithdrawn();
        uint256 amount = claimable(loanId, msg.sender);
        if (amount == 0) revert NothingOwed();
        withdrawn[loanId][msg.sender] = true;
        _push(_terms[loanId].asset, msg.sender, amount);
        emit Withdrawn(loanId, msg.sender, amount);
    }

    // ---------------------------------------------------------------- views

    function terms(uint256 loanId) external view returns (Terms memory) {
        return _terms[loanId];
    }

    function loan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    function lenders(uint256 loanId, Tranche tranche) external view returns (address[] memory) {
        return _lenders[loanId][tranche];
    }

    function payouts(uint256 loanId) external view returns (Commitments.Payout[] memory) {
        return _payouts[loanId];
    }

    function seniorOwed(uint256 loanId) public view returns (uint256) {
        Terms storage t = _terms[loanId];
        return t.seniorTarget + t.seniorTarget * t.seniorRateBps / BPS;
    }

    function juniorOwed(uint256 loanId) public view returns (uint256) {
        Terms storage t = _terms[loanId];
        return t.juniorTarget + t.juniorTarget * t.juniorRateBps / BPS;
    }

    function totalOwed(uint256 loanId) public view returns (uint256) {
        return seniorOwed(loanId) + juniorOwed(loanId);
    }

    // ---------------------------------------------------------------- rulings

    function _settleDispute(uint256 loanId, bool isDefault) private {
        Loan storage l = _loans[loanId];
        IERC20 asset = _terms[loanId].asset;
        if (isDefault) {
            // The claim was right: the claimant gets both bonds.
            _push(asset, l.claimant, 2 * claimBond);
            _ruleDefault(loanId);
        } else {
            // The borrower proved they paid off-chain: they get both bonds and their collateral back.
            _push(asset, l.borrower, 2 * claimBond);
            l.status = Status.Repaid;
            _ruleRelease(loanId);
        }
    }

    /// @dev All collateral back to the borrower.
    function _ruleRelease(uint256 loanId) private {
        Commitments.Payout[] memory p = new Commitments.Payout[](1);
        p[0] = Commitments.Payout(_loans[loanId].borrower, _terms[loanId].collateralAmount);
        _record(loanId, p);
    }

    /// @dev Default: what is still owed is covered from the collateral, senior lenders first,
    ///      then junior lenders; anything left over goes back to the borrower.
    function _ruleDefault(uint256 loanId) private {
        Loan storage l = _loans[loanId];
        Terms storage t = _terms[loanId];
        l.status = Status.Defaulted;

        (uint256 seniorPool, uint256 juniorPool) = _assetWaterfall(loanId);
        uint256 seniorShort = seniorOwed(loanId) - seniorPool;
        uint256 juniorShort = juniorOwed(loanId) - juniorPool;

        uint256 left = t.collateralAmount;
        uint256 seniorColl = _min(left, _ceilDiv(seniorShort * 1e18, t.settlementPrice));
        left -= seniorColl;
        uint256 juniorColl = _min(left, _ceilDiv(juniorShort * 1e18, t.settlementPrice));
        left -= juniorColl;

        address[] storage sl = _lenders[loanId][Tranche.Senior];
        address[] storage jl = _lenders[loanId][Tranche.Junior];
        Commitments.Payout[] memory p = new Commitments.Payout[](sl.length + jl.length + 1);
        uint256 n;
        n = _split(loanId, Tranche.Senior, sl, t.seniorTarget, seniorColl, p, n);
        n = _split(loanId, Tranche.Junior, jl, t.juniorTarget, juniorColl, p, n);
        if (left != 0) p[n++] = Commitments.Payout(l.borrower, left);

        assembly {
            mstore(p, n) // trim unused slots
        }
        _record(loanId, p);
    }

    /// @dev Share `amount` across a tranche by contribution. The last lender takes the rounding dust,
    ///      so the shares always add up to exactly `amount`.
    function _split(
        uint256 loanId,
        Tranche tranche,
        address[] storage list,
        uint256 target,
        uint256 amount,
        Commitments.Payout[] memory p,
        uint256 n
    ) private view returns (uint256) {
        if (amount == 0) return n;
        uint256 given;
        uint256 len = list.length;
        for (uint256 i; i < len; ++i) {
            uint256 share = i == len - 1 ? amount - given : amount * contribution[loanId][tranche][list[i]] / target;
            given += share;
            if (share != 0) p[n++] = Commitments.Payout(list[i], share);
        }
        return n;
    }

    /// @dev Repayments made on Portaldot, split senior first.
    function _assetWaterfall(uint256 loanId) private view returns (uint256 seniorPool, uint256 juniorPool) {
        uint256 repaid = _loans[loanId].repaid;
        seniorPool = _min(repaid, seniorOwed(loanId));
        juniorPool = _min(repaid - seniorPool, juniorOwed(loanId));
    }

    function _record(uint256 loanId, Commitments.Payout[] memory p) private {
        Terms storage t = _terms[loanId];
        bytes32 c = Commitments.ruling(
            block.chainid, address(this), loanId, t.vaultChainId, t.vault, _loans[loanId].depositId, p
        );
        rulingOf[loanId] = c;
        for (uint256 i; i < p.length; ++i) {
            _payouts[loanId].push(p[i]);
        }
        emit Ruled(loanId, _loans[loanId].status, c, p);
    }

    // ---------------------------------------------------------------- token helpers

    function _pull(IERC20 asset, address from, uint256 amount) private {
        if (!asset.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(IERC20 asset, address to, uint256 amount) private {
        if (amount != 0 && !asset.transfer(to, amount)) revert TransferFailed();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
