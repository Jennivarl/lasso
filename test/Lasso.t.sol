// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, Vm} from "forge-std/Test.sol";
import {Lasso} from "../src/Lasso.sol";
import {LassoVault} from "../src/LassoVault.sol";
import {AttestedRoad} from "../src/roads/AttestedRoad.sol";
import {Commitments} from "../src/libraries/Commitments.sol";

/// @dev Both chains are simulated on one test chain: the vault plays Ethereum, Lasso plays Portaldot.
///      Loan money is native POT; collateral is native ETH on the vault side.
contract LassoTest is Test {
    Lasso lasso;
    LassoVault vault;
    AttestedRoad road;

    uint256 attesterKey = 0xA77E57;
    address borrower = makeAddr("borrower");
    address senior = makeAddr("senior");
    address junior = makeAddr("junior");
    address a0 = makeAddr("arbiter0");
    address a1 = makeAddr("arbiter1");
    address a2 = makeAddr("arbiter2");

    uint64 constant GRACE = 1 days;
    uint64 constant WINDOW = 2 days;
    uint128 constant BOND = 100 ether;
    bytes32 constant ROAD_IN_TAG = keccak256("LASSO_ATTESTED_ROAD_IN_V1");
    uint8 constant OPEN = 1;
    uint8 constant ACTIVE = 2;
    uint8 constant IN_CLAIM = 3;
    uint8 constant DISPUTED = 4;
    uint8 constant REPAID = 5;
    uint8 constant DEFAULTED = 6;
    uint8 constant CANCELLED = 7;

    uint256 id;
    uint256 depositId;
    uint64 dueAt;
    Commitments.Payouts lastPayouts;

    function setUp() public {
        address attester = vm.addr(attesterKey);
        road = new AttestedRoad(attester);
        vault = new LassoVault(road);
        lasso = new Lasso(attester, [a0, a1, a2], GRACE, WINDOW, BOND);
        vm.deal(borrower, 50_000 ether);
        vm.deal(senior, 50_000 ether);
        vm.deal(junior, 50_000 ether);
    }

    // ------------------------------------------------------------ helpers

    /// @dev Example loan: 6,000 POT senior at 5% + 4,000 POT junior at 15% = 10,900 owed,
    ///      backed by 10 ETH, settled at 1 ETH = 2,000 POT.
    function _request(uint128 price) internal returns (uint256 loanId) {
        dueAt = uint64(block.timestamp + 30 days);
        uint256 amounts = uint256(6_000 ether) << 128 | 4_000 ether;
        uint256 backing = uint256(10 ether) << 128 | price;
        uint256 schedule = uint256(block.chainid) << 192 | uint256(block.timestamp + 1 days) << 128 | uint256(dueAt)
            << 64 | uint256(500) << 16 | 1_500;
        vm.prank(borrower);
        loanId = lasso.request(address(vault), amounts, backing, schedule);
    }

    function _sign(bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(attesterKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        return abi.encodePacked(r, s, v);
    }

    function _depositProof(uint256 loanId, uint256 dep) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                ROAD_IN_TAG, block.chainid, address(lasso), block.chainid, address(vault), dep, vault.commitments(dep)
            )
        );
        loanId; // the commitment already binds the loan
        return _sign(digest);
    }

    function _rulingProof(uint256 loanId) internal view returns (bytes memory) {
        return _sign(road.rulingDigest(block.chainid, address(lasso), loanId, lasso.rulingOf(loanId)));
    }

    function _lockAndProve(uint256 loanId) internal {
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), loanId);
        lasso.prove(loanId, uint64(depositId), _depositProof(loanId, depositId));
    }

    function _active() internal {
        id = _request(2_000 ether);
        _lockAndProve(id);
        vm.prank(senior);
        lasso.fund{value: 6_000 ether}(id, true);
        vm.prank(junior);
        lasso.fund{value: 4_000 ether}(id, false);
    }

    function _status(uint256 loanId) internal view returns (uint8) {
        bytes32 slot0 = vm.load(address(lasso), keccak256(abi.encode(loanId, uint256(1))));
        return uint8(uint256(slot0) >> 160);
    }

    /// @dev Starts recording; call _capture() after the action that rules.
    function _watch() internal {
        vm.recordLogs();
    }

    function _capture() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Ruled(uint256,bytes32,(address[3],uint256[3]))");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (, Commitments.Payouts memory p) = abi.decode(logs[i].data, (bytes32, Commitments.Payouts));
                lastPayouts = p;
            }
        }
    }

    function _execute() internal {
        vault.execute(depositId, lastPayouts, _rulingProof(id));
    }

    function _claim() internal {
        vm.warp(dueAt + GRACE + 1);
        vm.prank(senior);
        lasso.claim{value: BOND}(id, keccak256("missed both payments"));
    }

    // ------------------------------------------------------------ stories

    function test_FundingStartsLoan_PrincipalToBorrower() public {
        _active();
        assertEq(_status(id), ACTIVE);
        assertEq(borrower.balance, 59_990 ether); // 50,000 - 10 ETH locked + 10,000 principal
    }

    function test_RepaidInFull_LendersPaidAsMoneyArrives_CollateralBack() public {
        _active();
        _watch();
        vm.prank(borrower);
        lasso.repay{value: 10_900 ether}(id);
        _capture();
        assertEq(_status(id), REPAID);
        assertEq(senior.balance, 50_000 ether + 300 ether); // 6,000 at 5%
        assertEq(junior.balance, 50_000 ether + 600 ether); // 4,000 at 15%

        assertEq(lastPayouts.to[2], borrower);
        assertEq(lastPayouts.amount[2], 10 ether);
        _execute();
        assertEq(borrower.balance, 50_000 ether - 900 ether - 10 ether + 10 ether + 0); // net interest paid
    }

    function test_PartialRepayment_GoesToSeniorFirst() public {
        _active();
        vm.prank(borrower);
        lasso.repay{value: 6_000 ether}(id);
        assertEq(senior.balance, 50_000 ether); // got 6,000 back of 6,300 owed
        assertEq(junior.balance, 46_000 ether); // nothing yet
        vm.prank(borrower);
        lasso.repay{value: 1_000 ether}(id);
        assertEq(senior.balance, 50_300 ether); // senior now whole
        assertEq(junior.balance, 46_700 ether); // junior gets the rest
    }

    function test_DefaultUnanswered_SeniorThenJuniorThenBorrower() public {
        _active();
        vm.prank(borrower);
        lasso.repay{value: 3_000 ether}(id);
        _claim();
        vm.warp(block.timestamp + WINDOW + 1);
        _watch();
        lasso.finalize(id);
        _capture();
        assertEq(_status(id), DEFAULTED);

        // Senior owed 6,300, got 3,000 -> short 3,300 = 1.65 ETH. Junior short 4,600 = 2.30 ETH.
        assertEq(lastPayouts.to[0], senior);
        assertEq(lastPayouts.amount[0], 1.65 ether);
        assertEq(lastPayouts.to[1], junior);
        assertEq(lastPayouts.amount[1], 2.3 ether);
        assertEq(lastPayouts.to[2], borrower);
        assertEq(lastPayouts.amount[2], 6.05 ether);

        uint256 sb = senior.balance;
        _execute();
        assertEq(senior.balance - sb, 1.65 ether);
        assertEq(senior.balance, 50_000 ether - 6_000 ether + 3_000 ether + 1.65 ether); // bond returned too
    }

    function test_CollateralTooSmall_SeniorTakesAll() public {
        id = _request(500 ether); // 10 ETH covers only 5,000
        _lockAndProve(id);
        vm.prank(senior);
        lasso.fund{value: 6_000 ether}(id, true);
        vm.prank(junior);
        lasso.fund{value: 4_000 ether}(id, false);
        _claim();
        vm.warp(block.timestamp + WINDOW + 1);
        _watch();
        lasso.finalize(id);
        _capture();
        assertEq(lastPayouts.amount[0], 10 ether);
        assertEq(lastPayouts.amount[1], 0);
        assertEq(lastPayouts.amount[2], 0);
        assertEq(lastPayouts.to[1], address(0));
        _execute();
    }

    function test_Dispute_PanelSaysPaidOffChain() public {
        _active();
        _claim();
        vm.prank(borrower);
        lasso.answer{value: BOND}(id, keccak256("bank receipt #8812"));
        assertEq(_status(id), DISPUTED);
        vm.prank(a0);
        lasso.vote(id, false);
        _watch();
        vm.prank(a2);
        lasso.vote(id, false);
        _capture();
        assertEq(_status(id), REPAID);
        assertEq(borrower.balance, 59_990 ether + BOND); // paid one bond, got two
        _execute();
        assertEq(borrower.balance, 60_000 ether + BOND); // + the 10 ETH collateral back
    }

    function test_Dispute_PanelConfirmsDefault() public {
        _active();
        _claim();
        vm.prank(borrower);
        lasso.answer{value: BOND}(id, keccak256("fake receipt"));
        vm.prank(a0);
        lasso.vote(id, true);
        vm.prank(a1);
        lasso.vote(id, true);
        assertEq(_status(id), DEFAULTED);
        assertEq(senior.balance, 44_000 ether + BOND); // paid one bond, got two
    }

    function test_Dispute_NoQuorum_DefaultStands() public {
        _active();
        _claim();
        vm.prank(borrower);
        lasso.answer{value: BOND}(id, 0);
        vm.prank(a0);
        lasso.vote(id, false);
        vm.prank(a1);
        lasso.vote(id, true);
        vm.warp(block.timestamp + WINDOW + 1);
        lasso.finalize(id);
        assertEq(_status(id), DEFAULTED);
        assertEq(senior.balance, 44_000 ether + BOND);
    }

    function test_RepayDuringClaim_ClosesItAndReturnsBond() public {
        _active();
        _claim();
        vm.prank(borrower);
        lasso.repay{value: 10_900 ether}(id);
        assertEq(_status(id), REPAID);
        assertEq(senior.balance, 50_300 ether); // repaid with interest, bond back
    }

    function test_Cancel_RefundsAndReleases() public {
        id = _request(2_000 ether);
        _lockAndProve(id);
        vm.prank(senior);
        lasso.fund{value: 6_000 ether}(id, true);
        vm.warp(block.timestamp + 1 days + 1);
        _watch();
        lasso.cancel(id);
        _capture();
        assertEq(_status(id), CANCELLED);
        assertEq(senior.balance, 50_000 ether);
        _execute();
        assertEq(borrower.balance, 50_000 ether);
    }

    // ------------------------------------------------------------ attacks and mistakes

    function test_Vault_RejectsTamperedPayouts() public {
        _active();
        _claim();
        vm.warp(block.timestamp + WINDOW + 1);
        _watch();
        lasso.finalize(id);
        _capture();
        Commitments.Payouts memory p = lastPayouts;
        p.to[2] = makeAddr("thief");
        bytes memory proof = _rulingProof(id);
        vm.expectRevert(LassoVault.RulingNotProven.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Vault_RejectsWrongTotal_AndPaysOnce() public {
        _active();
        _watch();
        vm.prank(borrower);
        lasso.repay{value: 10_900 ether}(id);
        _capture();
        Commitments.Payouts memory p = lastPayouts;
        p.amount[2] = 9 ether;
        bytes memory proof = _rulingProof(id);
        vm.expectRevert(abi.encodeWithSelector(LassoVault.PayoutMismatch.selector, 10 ether, 9 ether));
        vault.execute(depositId, p, proof);

        _execute();
        p = lastPayouts;
        vm.expectRevert(LassoVault.AlreadySettled.selector);
        vault.execute(depositId, p, proof);
    }

    function test_Lasso_RejectsProofFromWrongKey() public {
        id = _request(2_000 ether);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), id);
        bytes32 digest = keccak256(
            abi.encode(
                ROAD_IN_TAG,
                block.chainid,
                address(lasso),
                block.chainid,
                address(vault),
                depositId,
                vault.commitments(depositId)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(0xBAD, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)));
        vm.expectRevert();
        lasso.prove(id, uint64(depositId), abi.encodePacked(r, s, v));
    }

    function test_Lasso_RejectsCollateralLockedForAnotherLoan() public {
        id = _request(2_000 ether);
        vm.prank(borrower);
        depositId = vault.lock{value: 10 ether}(block.chainid, address(lasso), id + 7);
        bytes memory proof = _depositProof(id, depositId);
        vm.expectRevert();
        lasso.prove(id, uint64(depositId), proof);
    }

    function test_Lasso_RejectsWrongCollateralAmount() public {
        id = _request(2_000 ether);
        vm.prank(borrower);
        depositId = vault.lock{value: 9 ether}(block.chainid, address(lasso), id);
        bytes memory proof = _depositProof(id, depositId);
        vm.expectRevert();
        lasso.prove(id, uint64(depositId), proof);
    }

    function test_Lasso_NoFundingBeforeProof_NoWrongAmount_NoSelfFunding() public {
        id = _request(2_000 ether);
        vm.prank(senior);
        vm.expectRevert();
        lasso.fund{value: 6_000 ether}(id, true);

        _lockAndProve(id);
        vm.prank(senior);
        vm.expectRevert();
        lasso.fund{value: 5_000 ether}(id, true);

        vm.prank(borrower);
        vm.expectRevert();
        lasso.fund{value: 6_000 ether}(id, true);
    }

    function test_Lasso_ClaimRules() public {
        _active();
        vm.warp(dueAt + GRACE);
        vm.prank(senior);
        vm.expectRevert(); // too early
        lasso.claim{value: BOND}(id, 0);

        vm.warp(dueAt + GRACE + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // not a lender
        lasso.claim{value: BOND}(id, 0);

        vm.prank(senior);
        vm.expectRevert(); // no bond
        lasso.claim(id, 0);
    }

    function test_Lasso_VoteRules() public {
        _active();
        _claim();
        vm.prank(borrower);
        lasso.answer{value: BOND}(id, 0);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        lasso.vote(id, false);

        vm.prank(a0);
        lasso.vote(id, true);
        vm.prank(a0);
        vm.expectRevert(); // twice
        lasso.vote(id, true);

        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(a1);
        vm.expectRevert(); // too late
        lasso.vote(id, true);
    }

    function test_Lasso_LateAnswerRejected() public {
        _active();
        _claim();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(borrower);
        vm.expectRevert();
        lasso.answer{value: BOND}(id, 0);
    }

    function test_Lasso_CannotOverpay() public {
        _active();
        vm.prank(borrower);
        vm.expectRevert();
        lasso.repay{value: 10_901 ether}(id);
    }

    /// @dev Whatever the numbers, a default ruling pays out exactly the locked collateral,
    ///      and the vault accepts it.
    function testFuzz_DefaultPayoutsSumToCollateral(uint96 repaid, uint96 price) public {
        id = _request(uint128(bound(price, 1e15, 1e24)));
        _lockAndProve(id);
        vm.prank(senior);
        lasso.fund{value: 6_000 ether}(id, true);
        vm.prank(junior);
        lasso.fund{value: 4_000 ether}(id, false);
        uint256 r = bound(repaid, 0, 10_900 ether - 1);
        if (r != 0) {
            vm.prank(borrower);
            lasso.repay{value: r}(id);
        }
        _claim();
        vm.warp(block.timestamp + WINDOW + 1);
        _watch();
        lasso.finalize(id);
        _capture();
        assertEq(lastPayouts.amount[0] + lastPayouts.amount[1] + lastPayouts.amount[2], 10 ether);
        _execute();
    }
}
