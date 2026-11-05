# Courthouse

**An on-chain bankruptcy court on Portaldot, with a long arm that reaches collateral on other chains.**

Portaldot's own roadmap names DaaS (Default-as-a-Service), an on-chain court for defaults, as its flagship protocol. Courthouse is a working version of that idea:

- A business borrows on **Portaldot** against ETH that stays locked on **Ethereum**.
- If it repays, the ETH goes back to it.
- If it stops paying, lenders file a claim, the borrower can answer, a panel of arbiters decides, and the ruling pays lenders out of the ETH: **senior lenders first, then junior lenders, then any surplus back to the borrower.**
- The Ethereum vault only moves money when it can check the Portaldot ruling for itself.

## How it fits together

```
     ETHEREUM                                   PORTALDOT
   ┌──────────────────┐   Road In  →         ┌──────────────────┐
   │  LongArmVault    │  "the ETH is locked"  │   Courthouse     │
   │  holds the ETH   │                       │  loans, claims,  │
   │                  │  ← Road Out           │  votes, rulings  │
   └──────────────────┘  "the court ruled"    └──────────────────┘
```

| Contract | Chain | Job |
|---|---|---|
| [`Courthouse.sol`](src/Courthouse.sol) | Portaldot | Loans in two tranches (senior / junior), repayment, claims, answers, arbiter votes, rulings |
| [`LongArmVault.sol`](src/LongArmVault.sol) | Ethereum | Locks ETH for a loan, pays it out exactly as a proven ruling says, once |
| [`Commitments.sol`](src/libraries/Commitments.sol) | both | The two messages that cross chains, hashed identically on both sides |
| [`IRoads.sol`](src/interfaces/IRoads.sol) | both | The two roads: Road In (Ethereum → Portaldot) and Road Out (Portaldot → Ethereum) |
| [`AttestedRoad.sol`](src/roads/AttestedRoad.sol) | both | **Temporary** road (see below) |

### The life of a loan

1. **Request:** the borrower posts terms: how much from senior and junior lenders, interest per tranche, due date, collateral amount, and the settlement price used if it defaults.
2. **Lock:** the borrower locks ETH in the vault on Ethereum.
3. **Prove:** anyone proves the lock to the Courthouse through Road In. Lenders can't fund until this is done.
4. **Fund and draw down:** lenders fill both tranches, and the borrower takes the money.
5. **Repay:** the loan is repaid in full, the Courthouse rules "release", and the vault returns the ETH.
6. **Or default:**
   - after the due date plus a grace period, a lender files a claim and posts a bond;
   - the borrower can answer with evidence (for example "I paid by bank transfer") and posts the same bond;
   - no answer means the default stands; with an answer, arbiters vote and a quorum decides;
   - if voting time runs out without a quorum, the default stands (the borrower missed the due date, so the burden of proof is on them);
   - whoever was wrong loses their bond to the other side.
7. **Ruling:** the Courthouse stores one hash of "who gets how much ETH". Road Out carries it to Ethereum, and the vault checks it, checks it adds up to exactly the locked ETH, and pays.

## Status: step 1 of 3

| Step | What | State |
|---|---|---|
| 1 | Courthouse, vault, full default process, tests | ✅ done |
| 2 | **Road Out as a ZK proof**: Ethereum checks Portaldot's validator signatures inside one SNARK | building |
| 3 | **Road In as a ZK proof**: Portaldot checks Ethereum's consensus inside one SNARK | next |

**Be aware:** until steps 2 and 3 land, both roads use [`AttestedRoad`](src/roads/AttestedRoad.sol), where **one signing key is trusted** to say "this happened on the other chain". It exists so everything else can be built and tested end to end now. The ZK roads replace it through the same interface, and the Courthouse and the vault don't change.

## How to Test

You only need a computer with internet. Nothing touches a real blockchain: the tests run both "chains" on a private simulated one, in under a second.

### 1. Install the two tools (one time)

- **Git**: download from <https://git-scm.com/downloads> and install with the default options.
- **Foundry** (the Solidity toolkit):
  - **macOS / Linux:** open a terminal and run:
    ```bash
    curl -L https://foundry.paradigm.xyz | bash
    foundryup
    ```
  - **Windows:** install Git first, open **Git Bash**, and run the same two commands.

  Check it worked:
  ```bash
  forge --version
  ```
  You should see something like `forge Version: 1.x`.

### 2. Get the code

```bash
git clone --recurse-submodules <this repository's URL>
cd courthouse
```

`--recurse-submodules` also downloads the testing library the tests use. If you forgot it, run `git submodule update --init`.

### 3. Run the tests

```bash
forge test
```

The first run downloads the Solidity compiler (about 10 seconds). Then you should see:

```
Suite result: ok. 19 passed; 0 failed; 0 skipped
```

To see each step of a test as it runs, add `-vvvv`, for example:

```bash
forge test --match-test test_DefaultUnanswered -vvvv
```

### 4. What the tests prove

Every test uses the same example loan: **10,000 mUSD borrowed against 10 ETH**. 6,000 comes from senior lenders at 5% and 4,000 from junior lenders at 15%, so **10,900 is owed**, and at settlement **1 ETH = 2,000 mUSD**.

| Test | The story | What should happen |
|---|---|---|
| `test_RepaidInFull_CollateralGoesBack` | Borrower repays 10,900 | All 10 ETH goes back to the borrower; each lender gets principal plus interest |
| `test_DefaultUnanswered_SeniorFirstThenJuniorThenBorrower` | Borrower repays only 3,000, a lender files a claim, no answer | The 3,000 goes to senior lenders. Seniors get 1.65 ETH (split 1.1 / 0.55), juniors get 2.30 ETH, the borrower keeps 6.05 ETH |
| `test_CollateralTooSmall_SeniorProtectedJuniorTakesLoss` | ETH is only worth 500 at settlement | Seniors take all 10 ETH; juniors absorb the loss |
| `test_Dispute_PanelSaysPaidOffChain` | Borrower answers "I paid by bank", 2 of 3 arbiters agree | Loan marked repaid, ETH released, borrower wins both bonds |
| `test_Dispute_PanelConfirmsDefault` | Borrower's answer is rejected by 2 arbiters | Default; the claimant wins both bonds |
| `test_Dispute_NoQuorum_BurdenOnBorrower` | Votes split 1–1 and time runs out | Default stands |
| `test_RepayDuringClaim_EndsItAndReturnsBonds` | Borrower pays in full after a claim was filed | Claim closed, bonds returned |
| `test_Cancel_RefundsLendersAndReleasesCollateral` | Loan never gets fully funded | Lenders refunded, ETH released |
| `test_Vault_RejectsTamperedPayouts` | Someone edits the payout list to send ETH to themselves | Vault refuses: the list no longer matches the ruling |
| `test_Vault_RejectsWrongTotal` | Payout list doesn't add up to the locked ETH | Vault refuses |
| `test_Vault_PaysOnlyOnce` | Same ruling sent twice | Second time refused |
| `test_Vault_RejectsProofFromWrongSigner` | Proof signed by the wrong key | Vault refuses |
| `test_Court_RejectsCollateralLockedForAnotherLoan` | ETH locked for a different loan | Courthouse refuses to count it |
| `test_Court_NoFundingBeforeCollateral` | Lender tries to fund before the ETH is proven | Refused |
| `test_Court_NoClaimBeforeDueDatePlusGrace` | Claim filed too early | Refused |
| `test_Court_OnlyLendersCanClaim` | A stranger files a claim | Refused |
| `test_Court_OnlyArbitersVote_AndNoConflicts` | A stranger votes; a lender who is also an arbiter votes; an arbiter votes twice | All refused |
| `test_Court_LateAnswerRejected` | Borrower answers after the window closed | Refused |
| `testFuzz_DefaultPayoutsAlwaysSumToCollateral` | 256 random loans, repayments and prices | Every ruling pays out **exactly** the locked ETH, and the vault accepts it |

## Tech notes

- Solidity 0.8.27, plain EVM bytecode. Portaldot V3's EVM (pallet-revive) runs it as is.
- Lenders use the same `0x…` address on both chains, so ETH payouts go straight to them.
- `rulingOf` (Courthouse) and `commitments` (vault) are kept as plain mappings on purpose: the ZK roads prove those exact storage slots.
- Arbiters and the road addresses are set by the deployer for now. That is temporary governance, and it's listed here so nobody mistakes it for the final design.

## Third-party code

- [forge-std](https://github.com/foundry-rs/forge-std) (MIT / Apache-2.0): test library only, not deployed.

## License

MIT
