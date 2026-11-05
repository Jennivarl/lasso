// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Lasso} from "../src/Lasso.sol";
import {LassoVault} from "../src/LassoVault.sol";
import {AttestedRoad} from "../src/roads/AttestedRoad.sol";
import {MockUSD} from "../src/mocks/MockUSD.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Commitments} from "../src/libraries/Commitments.sol";

/// @dev Both chains are simulated on one test chain: the vault plays Ethereum, Lasso plays Portaldot.
contract LassoTest is Test {
    Lasso lasso;
    LassoVault vault;
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
        vault = new LassoVault(road);
        lasso = new Lasso(road, GRACE, RESPOND, VOTE, BOND);
        usd = new MockUSD();

        lasso.setArbiter(a1, true);
        lasso.setArbiter(a2, true);
        lasso.setArbiter(a3, true);
        lasso.setQuorum(2);

        address[4] memory people = [borrower, s1, s2, j1];
        for (uint256 i; i < people.length; ++i) {
            usd.mint(people[i], 50_000e18);
            vm.prank(people[i]);
            usd.approve(address(lasso), type(uint256).max);
        }
        vm.deal(borrower, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _terms() internal view returns (Lasso.Terms memory t) {
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
        return _sign(road.rulingDigest(block.chainid, address(lasso), id, lasso.rulingOf(id)));
    }

    /// @dev Request, lock, prove, fund, draw down. Leaves the loan Active.
    function _activeLoan() internal {
        vm.prank(borrower);
        loanId = lasso.requestLoan(_terms());

        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId);
        lasso.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));

        vm.prank(s1);
        lasso.fund(loanId, Lasso.Tranche.Senior, 4_000e18);
        vm.prank(s2);
        lasso.fund(loanId, Lasso.Tranche.Senior, 2_000e18);
        vm.prank(j1);
        lasso.fund(loanId, Lasso.Tranche.Junior, 4_000e18);

        vm.prank(borrower);
        lasso.drawdown(loanId);
    }

    function _executeRuling() internal {
        vault.execute(depositId, lasso.payouts(loanId), _rulingProof(loanId));
    }

    function _status() internal view returns (Lasso.Status) {
        return lasso.loan(loanId).status;
    }

    function _fileClaimAfterDue() internal {
        vm.warp(lasso.terms(loanId).dueDate + GRACE + 1);
        vm.prank(s1);
        lasso.fileClaim(loanId, keccak256("missed both payments"));
    }

    // ------------------------------------------------------------ stories

    function test_RepaidInFull_CollateralGoesBack() public {
        _activeLoan();
        assertEq(usd.balanceOf(borrower), 60_000e18); // 50k + 10k borrowed

        vm.prank(borrower);
        lasso.repay(loanId, 10_900e18); // 6,300 senior + 4,600 junior
        assertEq(uint8(_status()), uint8(Lasso.Status.Repaid));

        _executeRuling();
        assertEq(borrower.balance, 10 ether);

        vm.prank(s1);
        lasso.withdraw(loanId);
        vm.prank(s2);
        lasso.withdraw(loanId);
        vm.prank(j1);
        lasso.withdraw(loanId);
        assertEq(usd.balanceOf(s1), 50_000e18 + 200e18); // 4,000 at 5%
        assertEq(usd.balanceOf(s2), 50_000e18 + 100e18); // 2,000 at 5%
        assertEq(usd.balanceOf(j1), 50_000e18 + 600e18); // 4,000 at 15%
    }

    function test_DefaultUnanswered_SeniorFirstThenJuniorThenBorrower() public {
        _activeLoan();
        vm.prank(borrower);
        lasso.repay(loanId, 3_000e18); // partial

        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        lasso.finalizeUnanswered(loanId);
        assertEq(uint8(_status()), uint8(Lasso.Status.Defaulted));

        // Senior is owed 6,300 and got 3,000 -> short 3,300 = 1.65 ETH.
        // Junior is owed 4,600 and got 0     -> short 4,600 = 2.30 ETH.
        // Borrower gets the rest: 6.05 ETH.
        Commitments.Payout[] memory p = lasso.payouts(loanId);
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
        assertEq(lasso.claimable(loanId, s1), 2_000e18);
        assertEq(lasso.claimable(loanId, s2), 1_000e18);
        assertEq(lasso.claimable(loanId, j1), 0);
        // Claimant got their bond back.
        assertEq(usd.balanceOf(s1), 50_000e18 - 4_000e18);
    }

    function test_CollateralTooSmall_SeniorProtectedJuniorTakesLoss() public {
        // Settlement price crashed: 1 ETH = 500 mUSD, so 10 ETH covers only 5,000 of 10,900 owed.
        Lasso.Terms memory t = _terms();
        t.settlementPrice = 500e18;
        vm.prank(borrower);
        loanId = lasso.requestLoan(t);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId);
        lasso.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        lasso.fund(loanId, Lasso.Tranche.Senior, 6_000e18);
        vm.prank(j1);
        lasso.fund(loanId, Lasso.Tranche.Junior, 4_000e18);
        vm.prank(borrower);
        lasso.drawdown(loanId);

        vm.warp(t.dueDate + GRACE + 1);
        vm.prank(s1);
        lasso.fileClaim(loanId, keccak256("nothing paid"));
        vm.warp(block.timestamp + RESPOND + 1);
        lasso.finalizeUnanswered(loanId);

        // Senior needs 6,300 / 500 = 12.6 ETH but only 10 exist: senior takes all of it.
        Commitments.Payout[] memory p = lasso.payouts(loanId);
        assertEq(p.length, 1);
        assertEq(p[0].to, s1);
        assertEq(p[0].amount, 10 ether);
    }

    function test_Dispute_PanelSaysPaidOffChain() public {
        _activeLoan();
        _fileClaimAfterDue();

        vm.prank(borrower);
        lasso.answerClaim(loanId, keccak256("bank transfer receipt #8812"));
        assertEq(uint8(_status()), uint8(Lasso.Status.Disputed));

        vm.prank(a1);
        lasso.vote(loanId, false);
        vm.prank(a2);
        lasso.vote(loanId, false);
        assertEq(uint8(_status()), uint8(Lasso.Status.Repaid));

        _executeRuling();
        assertEq(borrower.balance, 10 ether);
        // Borrower: 60,000 after drawdown, -100 bond, +200 both bonds.
        assertEq(usd.balanceOf(borrower), 60_100e18);
    }

    function test_Dispute_PanelConfirmsDefault() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        lasso.answerClaim(loanId, keccak256("fake receipt"));

        vm.prank(a1);
        lasso.vote(loanId, true);
        vm.prank(a3);
        lasso.vote(loanId, true);
        assertEq(uint8(_status()), uint8(Lasso.Status.Defaulted));
        // Claimant: 46,000 after funding, -100 bond, +200 both bonds.
        assertEq(usd.balanceOf(s1), 46_100e18);
    }

    function test_Dispute_NoQuorum_BurdenOnBorrower() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        lasso.answerClaim(loanId, keccak256("receipt"));
        vm.prank(a1);
        lasso.vote(loanId, false);
        vm.prank(a2);
        lasso.vote(loanId, true);

        vm.warp(block.timestamp + VOTE + 1);
        lasso.resolveExpired(loanId);
        assertEq(uint8(_status()), uint8(Lasso.Status.Defaulted));
    }

    function test_RepayDuringClaim_EndsItAndReturnsBonds() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        lasso.repay(loanId, 10_900e18);
        assertEq(uint8(_status()), uint8(Lasso.Status.Repaid));
        assertEq(usd.balanceOf(s1), 46_000e18); // bond back
    }

    function test_Cancel_RefundsLendersAndReleasesCollateral() public {
        vm.prank(borrower);
        loanId = lasso.requestLoan(_terms());
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId);
        lasso.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        lasso.fund(loanId, Lasso.Tranche.Senior, 1_000e18);

        vm.warp(block.timestamp + 1 days + 1);
        lasso.cancel(loanId); // anyone, after the funding deadline
        _executeRuling();
        assertEq(borrower.balance, 10 ether);

        vm.prank(s1);
        lasso.withdraw(loanId);
        assertEq(usd.balanceOf(s1), 50_000e18);
    }

    // ------------------------------------------------------------ attacks and mistakes

    function test_Vault_RejectsTamperedPayouts() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        lasso.finalizeUnanswered(loanId);

        Commitments.Payout[] memory p = lasso.payouts(loanId);
        bytes memory proof = _rulingProof(loanId);
        // Swap who gets the borrower's surplus.
        p[3].to = makeAddr("thief");
        vm.expectRevert(LassoVault.RulingNotProven.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Vault_RejectsWrongTotal() public {
        _activeLoan();
        vm.prank(borrower);
        lasso.repay(loanId, 10_900e18);
        Commitments.Payout[] memory p = lasso.payouts(loanId);
        p[0].amount = 9 ether;
        bytes memory proof = _rulingProof(loanId);
        vm.expectRevert(abi.encodeWithSelector(LassoVault.PayoutMismatch.selector, 10 ether, 9 ether));
        vault.execute(depositId, p, proof);
    }

    function test_Vault_PaysOnlyOnce() public {
        _activeLoan();
        vm.prank(borrower);
        lasso.repay(loanId, 10_900e18);
        _executeRuling();
        Commitments.Payout[] memory p = lasso.payouts(loanId);
        bytes memory proof = _rulingProof(loanId);
        vm.expectRevert(LassoVault.AlreadySettled.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Vault_RejectsProofFromWrongSigner() public {
        _activeLoan();
        vm.prank(borrower);
        lasso.repay(loanId, 10_900e18);
        bytes32 digest = road.rulingDigest(block.chainid, address(lasso), loanId, lasso.rulingOf(loanId));
        bytes32 h = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, h);
        Commitments.Payout[] memory p = lasso.payouts(loanId);
        vm.expectRevert(LassoVault.RulingNotProven.selector);
        vault.execute(depositId, p, abi.encodePacked(r, s, v));
    }

    function test_Lasso_RejectsCollateralLockedForAnotherLoan() public {
        vm.prank(borrower);
        loanId = lasso.requestLoan(_terms());
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId + 7);
        bytes memory proof = _depositProof(depositId);
        vm.expectRevert(Lasso.CollateralNotProven.selector);
        lasso.confirmCollateral(loanId, depositId, 10 ether, proof);
    }

    function test_Lasso_NoFundingBeforeCollateral() public {
        vm.prank(borrower);
        loanId = lasso.requestLoan(_terms());
        vm.prank(s1);
        vm.expectRevert(Lasso.CollateralNotConfirmed.selector);
        lasso.fund(loanId, Lasso.Tranche.Senior, 1_000e18);
    }

    function test_Lasso_NoClaimBeforeDueDatePlusGrace() public {
        _activeLoan();
        vm.warp(lasso.terms(loanId).dueDate + GRACE);
        vm.prank(s1);
        vm.expectRevert(Lasso.TooEarly.selector);
        lasso.fileClaim(loanId, bytes32(0));
    }

    function test_Lasso_OnlyLendersCanClaim() public {
        _activeLoan();
        vm.warp(lasso.terms(loanId).dueDate + GRACE + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Lasso.NotLender.selector);
        lasso.fileClaim(loanId, bytes32(0));
    }

    function test_Lasso_OnlyArbitersVote_AndNoConflicts() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.prank(borrower);
        lasso.answerClaim(loanId, bytes32(0));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Lasso.NotArbiter.selector);
        lasso.vote(loanId, false);

        lasso.setArbiter(j1, true); // a lender on this loan
        vm.prank(j1);
        vm.expectRevert(Lasso.ConflictOfInterest.selector);
        lasso.vote(loanId, true);

        vm.prank(a1);
        lasso.vote(loanId, true);
        vm.prank(a1);
        vm.expectRevert(Lasso.AlreadyVoted.selector);
        lasso.vote(loanId, true);
    }

    function test_Lasso_LateAnswerRejected() public {
        _activeLoan();
        _fileClaimAfterDue();
        vm.warp(block.timestamp + RESPOND + 1);
        vm.prank(borrower);
        vm.expectRevert(Lasso.TooLate.selector);
        lasso.answerClaim(loanId, bytes32(0));
    }

    /// @dev Whatever the numbers, a default ruling pays out exactly the locked collateral.
    function testFuzz_DefaultPayoutsAlwaysSumToCollateral(uint96 repaid, uint96 price, uint96 sA, uint96 sB) public {
        uint256 senior1 = bound(sA, 1e18, 5_000e18);
        uint256 senior2 = bound(sB, 1e18, 5_000e18);
        Lasso.Terms memory t = _terms();
        t.seniorTarget = senior1 + senior2;
        t.settlementPrice = bound(price, 1e15, 1e24);

        vm.prank(borrower);
        loanId = lasso.requestLoan(t);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId);
        lasso.confirmCollateral(loanId, depositId, 10 ether, _depositProof(depositId));
        vm.prank(s1);
        lasso.fund(loanId, Lasso.Tranche.Senior, senior1);
        vm.prank(s2);
        lasso.fund(loanId, Lasso.Tranche.Senior, senior2);
        vm.prank(j1);
        lasso.fund(loanId, Lasso.Tranche.Junior, t.juniorTarget);
        vm.prank(borrower);
        lasso.drawdown(loanId);

        uint256 r = bound(repaid, 0, lasso.totalOwed(loanId) - 1);
        if (r != 0) {
            vm.prank(borrower);
            lasso.repay(loanId, r);
        }
        vm.warp(t.dueDate + GRACE + 1);
        vm.prank(s1);
        lasso.fileClaim(loanId, bytes32(0));
        vm.warp(block.timestamp + RESPOND + 1);
        lasso.finalizeUnanswered(loanId);

        Commitments.Payout[] memory p = lasso.payouts(loanId);
        uint256 sum;
        for (uint256 i; i < p.length; ++i) {
            sum += p[i].amount;
        }
        assertEq(sum, 10 ether);
        _executeRuling(); // and the vault accepts it
    }
}
