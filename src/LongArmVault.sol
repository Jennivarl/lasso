// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IRoadOut} from "./interfaces/IRoads.sol";
import {Commitments} from "./libraries/Commitments.sol";

/// @title LongArm Vault
/// @notice Lives on the collateral chain (Ethereum). Holds a borrower's ETH while their loan
///         runs on Portaldot, and pays it out only as a Courthouse ruling says.
/// @dev The vault never decides anything itself. It checks the ruling through Road Out,
///      checks that the ruling pays out exactly the locked amount, and pays once.
contract LongArmVault {
    struct Deposit {
        address depositor;
        uint256 amount;
        uint256 courthouseChainId;
        address courthouse;
        uint256 loanId;
        bool settled;
    }

    address public owner;
    IRoadOut public roadOut;

    uint256 public nextDepositId;
    mapping(uint256 => Deposit) public deposits;
    /// @notice Road In proves this slot. Keep it a plain mapping so the storage slot is predictable.
    mapping(uint256 => bytes32) public commitments;
    /// @notice ETH a payee could not receive directly; they can pull it with `withdrawCredit`.
    mapping(address => uint256) public credit;

    bool private _locked;

    event Locked(
        uint256 indexed depositId,
        address indexed depositor,
        uint256 amount,
        uint256 courthouseChainId,
        address courthouse,
        uint256 indexed loanId,
        bytes32 commitment
    );
    event Settled(uint256 indexed depositId, uint256 indexed loanId, bytes32 rulingCommitment);
    event Paid(uint256 indexed depositId, address indexed to, uint256 amount, bool direct);
    event RoadOutChanged(address road);

    error NotOwner();
    error ZeroAmount();
    error UnknownDeposit();
    error AlreadySettled();
    error PayoutMismatch(uint256 expected, uint256 got);
    error RulingNotProven();
    error Reentrancy();
    error NothingToWithdraw();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(IRoadOut road) {
        owner = msg.sender;
        roadOut = road;
        emit RoadOutChanged(address(road));
    }

    /// @notice Temporary: lets the owner swap the test road for the ZK road. Removed once the ZK road is live.
    function setRoadOut(IRoadOut road) external {
        if (msg.sender != owner) revert NotOwner();
        roadOut = road;
        emit RoadOutChanged(address(road));
    }

    /// @notice Lock ETH as collateral for loan `loanId` in the Courthouse at (`courthouseChainId`, `courthouse`).
    function lock(uint256 courthouseChainId, address courthouse, uint256 loanId)
        external
        payable
        returns (uint256 depositId)
    {
        if (msg.value == 0) revert ZeroAmount();
        depositId = nextDepositId++;
        deposits[depositId] = Deposit(msg.sender, msg.value, courthouseChainId, courthouse, loanId, false);
        bytes32 c = Commitments.deposit(
            block.chainid, address(this), depositId, msg.sender, msg.value, courthouseChainId, courthouse, loanId
        );
        commitments[depositId] = c;
        emit Locked(depositId, msg.sender, msg.value, courthouseChainId, courthouse, loanId, c);
    }

    /// @notice Carry out a Courthouse ruling. Anyone can call it; the proof is what matters.
    function execute(uint256 depositId, Commitments.Payout[] calldata payouts, bytes calldata proof)
        external
        nonReentrant
    {
        Deposit storage d = deposits[depositId];
        if (d.depositor == address(0)) revert UnknownDeposit();
        if (d.settled) revert AlreadySettled();

        uint256 total;
        for (uint256 i; i < payouts.length; ++i) {
            total += payouts[i].amount;
        }
        if (total != d.amount) revert PayoutMismatch(d.amount, total);

        bytes32 rc = Commitments.ruling(
            d.courthouseChainId, d.courthouse, d.loanId, block.chainid, address(this), depositId, payouts
        );
        if (!roadOut.verifyRuling(d.courthouseChainId, d.courthouse, d.loanId, rc, proof)) revert RulingNotProven();

        d.settled = true;
        emit Settled(depositId, d.loanId, rc);

        for (uint256 i; i < payouts.length; ++i) {
            _pay(depositId, payouts[i].to, payouts[i].amount);
        }
    }

    function withdrawCredit() external nonReentrant {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    /// @dev A payee that rejects ETH must not block everyone else, so failed sends become credit.
    function _pay(uint256 depositId, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 50_000}("");
        if (!ok) credit[to] += amount;
        emit Paid(depositId, to, amount, ok);
    }
}
