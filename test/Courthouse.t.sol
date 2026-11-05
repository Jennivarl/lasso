// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Courthouse} from "../src/Courthouse.sol";
import {LongArmVault} from "../src/LongArmVault.sol";
import {AttestedRoad} from "../src/roads/AttestedRoad.sol";
import {MockUSD} from "../src/mocks/MockUSD.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Commitments} from "../src/libraries/Commitments.sol";

/// @dev Both chains are simulated on one test chain: the vault plays Ethereum, the Courthouse plays Portaldot.
contract CourthouseTest is Test {
    Courthouse court;
    LongArmVault vault;
    AttestedRoad road;
    MockUSD usd;

    uint256 attesterKey = 0xA77E57;
    address borrower = makeAddr("borrower");
    address s1 = makeAddr("senior1");
    address s2 = makeAddr("senior2");
    address j1 = makeAddr("junior1");
    address a1 = makeAddr("arbiter1");
    address a2 = makeAddr("arbiter2");
    address a3 = makeAddr("arbiter3");

    uint64 constant GRACE = 1 days;
    uint64 constant RESPOND = 2 days;
    uint64 constant VOTE = 3 days;
    uint256 constant BOND = 100e18;

    uint256 loanId;
    uint256 depositId;

    function setUp() public {
        road = new AttestedRoad(vm.addr(attesterKey));
        vault = new LongArmVault(road);
        court = new Courthouse(road, GRACE, RESPOND, VOTE, BOND);
        usd = new MockUSD();

        court.setArbiter(a1, true);
        court.setArbiter(a2, true);
        court.setArbiter(a3, true);
        court.setQuorum(2);

        address[4] memory people = [borrower, s1, s2, j1];
        for (uint256 i; i < people.length; ++i) {
            usd.mint(people[i], 50_000e18);
            vm.prank(people[i]);
            usd.approve(address(court), type(uint256).max);
        }
        vm.deal(borrower, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _terms() internal view returns (Courthouse.Terms memory t) {
        t.asset = IERC20(address(usd));
        t.seniorTarget = 6_000e18;
        t.juniorTarget = 4_000e18;
        t.seniorRateBps = 500; // 5%
        t.juniorRateBps = 1_500; // 15%
        t.fundingDeadline = uint64(block.timestamp + 1 days);
        t.dueDate = uint64(block.timestamp + 30 days);
        t.vaultChainId = block.chainid;
        t.vault = address(vault);
        t.collateralAmount = 10 ether;
        t.settlementPrice = 2_000e18; // 1 ETH = 2,000 mUSD at settlement
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterKey, h);
        return abi.encodePacked(r, s, v);
    }

    function _depositProof(uint256 id) internal view returns (bytes memory) {
        return _sign(road.depositDigest(block.chainid, address(vault), id, vault.commitments(id)));
    }

    function _rulingProof(uint256 id) internal view returns (bytes memory) {
        return _sign(road.rulingDigest(block.chainid, address(court), id, court.rulingOf(id)));
    }

    /// @dev Request, lock, prove, fund, draw down. Leaves the loan Active.
    function _activeLoan() internal {
        vm.prank(borrower);
        loanId = court.requestLoan(_terms());

        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(court), loanId);
        court.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));

        vm.prank(s1);
        court.fund(loanId, Courthouse.Tranche.Senior, 4_000e18);
        vm.prank(s2);
        court.fund(loanId, Courthouse.Tranche.Senior, 2_000e18);
        vm.prank(j1);
        court.fund(loanId, Courthouse.Tranche.Junior, 4_000e18);

        vm.prank(borrower);
        court.drawdown(loanId);
    }

    function _executeRuling() internal {
        vault.execute(depositId, court.payouts(loanId), _rulingProof(loanId));
    }

    function _status() internal view returns (Courthouse.Status) {
        return court.loan(loanId).status;
    }

    function _fileClaimAfterDue() internal {
        vm.warp(court.terms(loanId).dueDate + GRACE + 1);
        vm.prank(s1);
        court.fileClaim(loanId, keccak256("missed both payments"));
    }

    // ------------------------------------------------------------ stories

    function test_RepaidInFull_CollateralGoesBack() public {
        _activeLoan();
        assertEq(usd.balanceOf(borrower), 60_000e18); // 50k + 10k borrowed

        vm.prank(borrower);
        court.repay(loanId, 10_900e18); // 6,300 senior + 4,600 junior
        assertEq(uint8(_status()), uint8(Courthouse.Status.Repaid));

        _executeRuling();
        assertEq(borrower.balance, 10 ether);

        vm.prank(s1);
        court.withdraw(loanId);
        vm.prank(s2);
        court.withdraw(loanId);
        vm.prank(j1);
        court.withdraw(loanId);
        assertEq(usd.balanceOf(s1), 50_000e18 + 200e18); // 4,000 at 5%
        assertEq(usd.balanceOf(s2), 50_000e18 + 100e18); // 2,000 at 5%
        assertEq(usd.balanceOf(j1), 50_000e18 + 600e18); // 4,000 at 15%
    }

    function test_DefaultUnanswered_SeniorFirstThenJuniorThenBorrower() public {
        _activeLoan();
        vm.prank(borrower);
        court.repay(loanId, 3_000e18); // partial

        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        court.finalizeUnanswered(loanId);
        assertEq(uint8(_status()), uint8(Courthouse.Status.Defaulted));

        // Senior is owed 6,300 and got 3,000 -> short 3,300 = 1.65 ETH.
        // Junior is owed 4,600 and got 0     -> short 4,600 = 2.30 ETH.
        // Borrower gets the rest: 6.05 ETH.
        Commitments.Payout[] memory p = court.payouts(loanId);
        assertEq(p.length, 4);
        assertEq(p[0].to, s1);
        assertEq(p[0].amount, 1.1 ether);
        assertEq(p[1].to, s2);
        assertEq(p[1].amount, 0.55 ether);
        assertEq(p[2].to, j1);
        assertEq(p[2].amount, 2.3 ether);
        assertEq(p[3].to, borrower);
        assertEq(p[3].amount, 6.05 ether);

        _executeRuling();
        assertEq(s1.balance, 1.1 ether);
        assertEq(s2.balance, 0.55 ether);
        assertEq(j1.balance, 2.3 ether);
        assertEq(borrower.balance, 6.05 ether);

        // The 3,000 repaid on Portaldot goes to senior lenders only.
        assertEq(court.claimable(loanId, s1), 2_000e18);
        assertEq(court.claimable(loanId, s2), 1_000e18);
        assertEq(court.claimable(loanId, j1), 0);
        // Claimant got their bond back.
        assertEq(usd.balanceOf(s1), 50_000e18 - 4_000e18);
    }

    function test_CollateralTooSmall_SeniorProtectedJuniorTakesLoss() public {
        // Settlement price crashed: 1 ETH = 500 mUSD, so 10 ETH covers only 5,000 of 10,900 owed.
        Courthouse.Terms memory t = _terms();
        t.settlementPrice = 500e18;
        vm.prank(borrower);
        loanId = court.requestLoan(t);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(court), loanId);
        court.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        court.fund(loanId, Courthouse.Tranche.Senior, 6_000e18);
        vm.prank(j1);
        court.fund(loanId, Courthouse.Tranche.Junior, 4_000e18);
        vm.prank(borrower);
        court.drawdown(loanId);

        vm.warp(t.dueDate + GRACE + 1);
        vm.prank(s1);
        court.fileClaim(loanId, keccak256("nothing paid"));
        vm.warp(block.timestamp + RESPOND + 1);
        court.finalizeUnanswered(loanId);

        // Senior needs 6,300 / 500 = 12.6 ETH but only 10 exist: senior takes all of it.
        Commitments.Payout[] memory p = court.payouts(loanId);
        assertEq(p.length, 1);
        assertEq(p[0].to, s1);
        assertEq(p[0].amount, 10 ether);
    }

    function test_Dispute_PanelSaysPaidOffChain() public {
        _activeLoan();
        _fileClaimAfterDue();

        vm.prank(borrower);
        court.answerClaim(loanId, keccak256("bank transfer receipt #8812"));
        assertEq(uint8(_status()), uint8(Courthouse.Status.Disputed));

        vm.prank(a1);
        court.vote(loanId, false);
        vm.prank(a2);
        court.vote(loanId, false);
        assertEq(uint8(_status()), uint8(Courthouse.Status.Repaid));

        _executeRuling();
        assertEq(borrower.balance, 10 ether);
        // Borrower: 60,000 after drawdown, -100 bond, +200 both bonds.
        assertEq(usd.balanceOf(borrower), 60_100e18);
    }

    function test_Dispute_PanelConfirmsDefault() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        court.answerClaim(loanId, keccak256("fake receipt"));

        vm.prank(a1);
        court.vote(loanId, true);
        vm.prank(a3);
        court.vote(loanId, true);
        assertEq(uint8(_status()), uint8(Courthouse.Status.Defaulted));
        // Claimant: 46,000 after funding, -100 bond, +200 both bonds.
        assertEq(usd.balanceOf(s1), 46_100e18);
    }

    function test_Dispute_NoQuorum_BurdenOnBorrower() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        court.answerClaim(loanId, keccak256("receipt"));
        vm.prank(a1);
        court.vote(loanId, false);
        vm.prank(a2);
        court.vote(loanId, true);

        vm.warp(block.timestamp + VOTE + 1);
        court.resolveExpired(loanId);
        assertEq(uint8(_status()), uint8(Courthouse.Status.Defaulted));
    }

    function test_RepayDuringClaim_EndsItAndReturnsBonds() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        court.repay(loanId, 10_900e18);
        assertEq(uint8(_status()), uint8(Courthouse.Status.Repaid));
        assertEq(usd.balanceOf(s1), 46_000e18); // bond back
    }

    function test_Cancel_RefundsLendersAndReleasesCollateral() public {
        vm.prank(borrower);
        loanId = court.requestLoan(_terms());
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(court), loanId);
        court.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        court.fund(loanId, Courthouse.Tranche.Senior, 1_000e18);

        vm.warp(block.timestamp + 1 days + 1);
        court.cancel(loanId); // anyone, after the funding deadline
        _executeRuling();
        assertEq(borrower.balance, 10 ether);

        vm.prank(s1);
        court.withdraw(loanId);
        assertEq(usd.balanceOf(s1), 50_000e18);
    }

    // ------------------------------------------------------------ attacks and mistakes

    function test_Vault_RejectsTamperedPayouts() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        court.finalizeUnanswered(loanId);

        Commitments.Payout[] memory p = court.payouts(loanId);
        bytes memory proof = _rulingProof(loanId);
        // Swap who gets the borrower's surplus.
        p[3].to = makeAddr("thief");
        vm.expectRevert(LongArmVault.RulingNotProven.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Vault_RejectsWrongTotal() public {
        _activeLoan();
        vm.prank(borrower);
        court.repay(loanId, 10_900e18);
        Commitments.Payout[] memory p = court.payouts(loanId);
        p[0].amount = 9 ether;
        bytes memory proof = _rulingProof(loanId);
        vm.expectRevert(abi.encodeWithSelector(LongArmVault.PayoutMismatch.selector, 10 ether, 9 ether));
        vault.execute(depositId, p, proof);
    }

    function test_Vault_PaysOnlyOnce() public {
        _activeLoan();
        vm.prank(borrower);
        court.repay(loanId, 10_900e18);
        _executeRuling();
        Commitments.Payout[] memory p = court.payouts(loanId);
        bytes memory proof = _rulingProof(loanId);
        vm.expectRevert(LongArmVault.AlreadySettled.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Vault_RejectsProofFromWrongSigner() public {
        _activeLoan();
        vm.prank(borrower);
        court.repay(loanId, 10_900e18);
        bytes32 digest = road.rulingDigest(block.chainid, address(court), loanId, court.rulingOf(loanId));
        bytes32 h = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, h);
        Commitments.Payout[] memory p = court.payouts(loanId);
        vm.expectRevert(LongArmVault.RulingNotProven.selector);
        vault.execute(depositId, p, abi.encodePacked(r, s, v));
    }

    function test_Court_RejectsCollateralLockedForAnotherLoan() public {
        vm.prank(borrower);
        loanId = court.requestLoan(_terms());
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(court), loanId + 7);
        bytes memory proof = _depositProof(depositId);
        vm.expectRevert(Courthouse.CollateralNotProven.selector);
        court.confirmCollateral(loanId, depositId, 10 ether, proof);
    }

    function test_Court_NoFundingBeforeCollateral() public {
        vm.prank(borrower);
        loanId = court.requestLoan(_terms());
        vm.prank(s1);
        vm.expectRevert(Courthouse.CollateralNotConfirmed.selector);
        court.fund(loanId, Courthouse.Tranche.Senior, 1_000e18);
    }

    function test_Court_NoClaimBeforeDueDatePlusGrace() public {
        _activeLoan();
        vm.warp(court.terms(loanId).dueDate + GRACE);
        vm.prank(s1);
        vm.expectRevert(Courthouse.TooEarly.selector);
        court.fileClaim(loanId, bytes32(0));
    }

    function test_Court_OnlyLendersCanClaim() public {
        _activeLoan();
        vm.warp(court.terms(loanId).dueDate + GRACE + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Courthouse.NotLender.selector);
        court.fileClaim(loanId, bytes32(0));
    }

    function test_Court_OnlyArbitersVote_AndNoConflicts() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        court.answerClaim(loanId, bytes32(0));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Courthouse.NotArbiter.selector);
        court.vote(loanId, false);

        court.setArbiter(j1, true); // a lender on this loan
        vm.prank(j1);
        vm.expectRevert(Courthouse.ConflictOfInterest.selector);
        court.vote(loanId, true);

        vm.prank(a1);
        court.vote(loanId, true);
        vm.prank(a1);
        vm.expectRevert(Courthouse.AlreadyVoted.selector);
        court.vote(loanId, true);
    }

    function test_Court_LateAnswerRejected() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        vm.prank(borrower);
        vm.expectRevert(Courthouse.TooLate.selector);
        court.answerClaim(loanId, bytes32(0));
    }

    /// @dev Whatever the numbers, a default ruling pays out exactly the locked collateral.
    function testFuzz_DefaultPayoutsAlwaysSumToCollateral(uint96 repaid, uint96 price, uint96 sA, uint96 sB) public {
        uint256 senior1 = bound(sA, 1e18, 5_000e18);
        uint256 senior2 = bound(sB, 1e18, 5_000e18);
        Courthouse.Terms memory t = _terms();
        t.seniorTarget = senior1 + senior2;
        t.settlementPrice = bound(price, 1e15, 1e24);

        vm.prank(borrower);
        loanId = court.requestLoan(t);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(court), loanId);
        court.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        court.fund(loanId, Courthouse.Tranche.Senior, senior1);
        vm.prank(s2);
        court.fund(loanId, Courthouse.Tranche.Senior, senior2);
        vm.prank(j1);
        court.fund(loanId, Courthouse.Tranche.Junior, t.juniorTarget);
        vm.prank(borrower);
        court.drawdown(loanId);

        uint256 r = bound(repaid, 0, court.totalOwed(loanId) - 1);
        if (r != 0) {
            vm.prank(borrower);
            court.repay(loanId, r);
        }
        vm.warp(t.dueDate + GRACE + 1);
        vm.prank(s1);
        court.fileClaim(loanId, bytes32(0));
        vm.warp(block.timestamp + RESPOND + 1);
        court.finalizeUnanswered(loanId);

        Commitments.Payout[] memory p = court.payouts(loanId);
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            sum += p[i].amount;
        }
        assertEq(sum, 10 ether);
        _executeRuling(); // and the vault accepts it
    }
}
