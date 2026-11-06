# Lasso

**Borrow on Portaldot against ETH that never leaves Ethereum. If you don't pay, Portaldot throws a lasso across chains and pulls the collateral home to your lenders, senior lender first.**

**App:** https://uselasso.vercel.app shows every loan read live from Portaldot and Sepolia, and lets you connect a wallet to act on one.

Portaldot's own site names **DaaS (Default-as-a-Service)**, on-chain default handling, as its flagship protocol: early warning, dispute resolution, asset seizure, liquidation, loss allocation, cross-chain settlement. Lasso is a working version of that idea, and it reaches across chains.

## The problem

Lending apps today handle one kind of failure: the collateral's price drops, so they sell it. They can't handle a **real-world default**, a business that simply stops paying, and they can't touch collateral sitting on **another chain**. Nobody decides who is right, and nobody decides who gets paid first.

## What Lasso does

1. **A business asks for a loan on Portaldot**, in two parts: a **senior** lender (paid first, lower interest) and a **junior** lender (paid second, higher interest).
2. **It locks ETH on Ethereum** in `LassoVault`. The ETH never moves to Portaldot.
3. **Road In** tells Portaldot the ETH is really locked. Lenders can't fund until it does.
4. **Both lenders fund**, and the loan starts. Repayments go straight to the lenders as they arrive, senior first.
5. **If the borrower stops paying**, after the due date plus a grace period a lender files a **claim** and posts a bond.
6. **The borrower can answer** with evidence (say, "I paid by bank transfer") and posts the same bond. Then **2 of 3 arbiters** decide. No answer, or no 2 matching votes in time, and the default stands, because the borrower missed the due date and the burden of proof is on them. Whoever was wrong loses their bond.
7. **Lasso rules**: who gets how much ETH, in order (senior, then junior, then any surplus back to the borrower). It stores one fingerprint of that ruling.
8. **Road Out** carries the ruling to Ethereum. The vault checks it against its own deposit, checks it adds up to exactly the locked ETH, and pays, **once**.

```
     ETHEREUM                                   PORTALDOT
   ┌──────────────────┐   Road In  →          ┌──────────────────┐
   │   LassoVault     │  "the ETH is locked"  │      Lasso       │
   │  holds the ETH   │                       │  loans, claims,  │
   │                  │  ← Road Out           │  votes, rulings  │
   └──────────────────┘  "the panel ruled"    └──────────────────┘
```

## Live deployments

| Contract | Chain | Address | Deploy transaction |
|---|---|---|---|
| **Lasso** | Portaldot V3 testnet (420420777) | `0x30e537B1FA7f59bE17440e9a49782d5Ff83D9dD1` | `0xab6f9a1de328dc451e170ea9d32a649a2b5e87b46ef7eaf9e4f61321130e021b` (block 341,767) |
| **LassoVault** | Ethereum Sepolia (11155111) | `0x7C813053C1bfbEFF48Af6f8568E24972768306E2` | `0x4c6e548bc17d04ca2d0be30a98d3941c8c5b0321fff8871b808ff33577e8b293` |
| **AttestedRoad** (Road Out, temporary) | Ethereum Sepolia | `0x3E8B7b6BcDEda05B89B93c66A7325e932A751fa8` | `0x5e92a7842c95092622e2094e1d0edfea849e2e371afec3854636ff467b25c352` |

## Built for Portaldot's storage deposits

Portaldot V3 (pallet-revive) holds a deposit for everything a contract stores. We read the numbers from the chain itself:

| Constant | Value |
|---|---|
| `Revive.DepositPerByte` | 0.06 POT |
| `Revive.DepositPerItem` | 0.15 POT |
| `CodeHashLockupDepositPercent` | 30% |

So deploying costs about **0.078 POT per byte of code**, and every new storage slot costs about **4 POT**. Lasso is designed around that:

- **One 5.9 KB contract** on Portaldot.
- **Native POT** instead of a token contract. The Road In check is built in, so there's no second contract.
- **A whole loan packed into 8 storage slots**, written in as few writes as possible.
- **Lenders are paid as money arrives** (senior first), so there's no withdraw bookkeeping.
- **The loan starts automatically** once fully funded.
- **Rulings are a fixed three-line payout** (senior, junior, borrower), so encoding is cheap on both chains.
- **State is read from events**, not view functions.

### What we traded to fit

Shrinking Lasso to fit Portaldot's deposits within our testnet budget meant giving some things up. None of these change how the money moves; they are on the list for the next version:

- **One senior and one junior lender per loan.** The first version allowed many lenders in each tranche.
- **Arbiters are fixed at deploy**, with no way to change the panel later.
- **Arbiters aren't checked against the loan's parties.** The first version stopped the borrower and lenders from voting on their own loan; the compact one relies on choosing independent arbiters at deploy.
- **A claimant that refuses its bond refund can block a full repayment during a claim.** The borrower can still answer the claim and win through the arbiters. The fix is to hold refunds for withdrawal instead of sending them.
- **Short, generic error messages**, so the app can't always say why a transaction was refused.
- **The Road In check is built into Lasso**, so moving that side to a ZK proof means a redeploy. The vault's Road Out can be swapped in place.

What stays the same: nobody can take the collateral without a valid ruling, a ruling can't be altered, nothing is paid twice, and the payout order is always senior, then junior, then the borrower. The 21 tests cover these.

**After the hackathon:** the code stays frozen while judging runs. Once the hackathon concludes, every item above will be fixed and Lasso redeployed as soon as we have enough testnet POT to cover the storage deposits.

## A real loan, end to end, on live chains

Loan #0: **0.05 POT senior at 5% + 0.03 POT junior at 15%**, backed by **0.001 ETH** locked on Sepolia, settled at 100 POT per ETH. The borrower never repaid. Every step below is a real transaction.

| # | Step | Chain | Transaction |
|---|---|---|---|
| 1 | Borrower requests the loan | Portaldot | `0x30e058109981677f6ccde457d29b29b12e4be6d5a1320910a920676920092a1e` |
| 2 | Borrower locks 0.001 ETH in LassoVault (deposit #0) | Sepolia | `0xb2af7f898b305d4415f990cbe9c75a8374ed0d2f827397e38be4a35650328f67` |
| 3 | Road In: Lasso accepts proof of the lock | Portaldot | `0x3f40ce31c8fcb073946a8ce127389ec44be2b52f5e311ffd20b0be25c5b6e259` |
| 4 | Senior lender funds | Portaldot | `0x827a846b7ce727e71d2cd3bf3d721a94cd49fe5a0b152f9c9cd2671002653db5` |
| 5 | Junior lender funds; the loan starts and pays the borrower | Portaldot | `0xdb26ef5c66fb71e530d258b43b428401570a06b5d028fbabfe5062af969c9092` |
| 6 | After due date + grace, senior files a default claim with a bond | Portaldot | `0x81a8ebc95db8101a75312382ccc7f861d51ede2e589413310a606dc461d159e6` |
| 7 | No answer in 3 minutes: default ruled (ruling `0x04c44567…77481aa2`) | Portaldot | `0xba8b7cf7c8fffaae65ba78ded568151f357dbeadddec7ad2be461fcc16523bb1` |
| 8 | Road Out: the vault pays the ruling, **senior 0.000525 ETH, junior 0.000345 ETH, borrower 0.00013 ETH** | Sepolia | `0x29430d67664625ef4d23f38108fab196d1912e39da230e179fabd2f0409d5a6e` |

Owed: senior 0.0525 POT = 0.000525 ETH, junior 0.0345 POT = 0.000345 ETH, and the remaining 0.00013 ETH went back to the borrower.

To keep deposits within budget, the live run skips a partial repayment, since every new value stored costs ~4 POT. The demo below shows the full story, partial repayment included, against local copies (forks) of both live chains, with the same deployed contracts at the same addresses.

## Status

| Piece | State |
|---|---|
| Lasso: loans, collateral proof, two-tranche repayment, claims, bonds, answers, arbiter votes, rulings | ✅ deployed on Portaldot V3 testnet |
| LassoVault: lock ETH, carry out a ruling exactly once | ✅ deployed on Sepolia |
| A real loan, request to payout, across both chains | ✅ done live (table above) |
| Full cross-chain story, scripted | ✅ runs on forks of both live chains |
| **Road In and Road Out as ZK proofs** | 🔜 next |

**Be aware:** today both roads are **attested**. One signing key vouches "this happened on the other chain", and whoever holds it is trusted. The vault and Lasso check only that signature, so swapping in a ZK proof changes the check and nothing else. The plan:
- **Road Out (Portaldot → Ethereum):** a SNARK that checks Portaldot's GRANDPA validator signatures (2 validators on V3 testnet, ed25519) and a storage proof of `rulingOf[loanId]`. Ethereum verifies one small proof, whatever the validator count. Portaldot's RPC already serves everything this needs (`grandpa_proveFinality`, `state_getReadProof`, `state_getChildReadProof`).
- **Road In (Ethereum → Portaldot):** a SNARK of Ethereum consensus (SP1 Helios) plus a storage proof of `commitments[depositId]`. We checked that Portaldot V3's EVM supports the BN254 pairing precompiles needed to verify it.

## How to Test

There are two things to try: the **tests** (about a minute) and the **full story demo** (about two minutes). Both run on a computer you control and touch no real money.

### 1. Install the tools (one time)

You need **Git**, **Foundry** (the Solidity toolkit), and **Python 3**.

- **Git:** <https://git-scm.com/downloads>, install with the defaults.
- **Foundry:** on macOS or Linux, open a terminal and run the two lines below. On Windows, run them inside **WSL** (Ubuntu).
  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  foundryup
  ```
- **Python 3:** already on macOS and Linux. Check with `python3 --version`.

Check Foundry worked:
```bash
forge --version
```
You should see `forge Version: 1.x`.

### 2. Get the code

```bash
git clone --recurse-submodules <this repository's URL>
cd lasso
```

### 3. Run the tests

```bash
forge test
```

The first run downloads the compiler (about 10 seconds). Then you should see:
```
Suite result: ok. 21 passed; 0 failed; 0 skipped
```

The tests run both "chains" on one simulated chain. They all use one example loan: **6,000 POT senior at 5% + 4,000 POT junior at 15% = 10,900 owed, backed by 10 ETH, settled at 1 ETH = 2,000 POT.**

| Test | The story | What should happen |
|---|---|---|
| `test_FundingStartsLoan_PrincipalToBorrower` | Both lenders fund | The loan starts and the borrower gets 10,000 POT |
| `test_RepaidInFull_LendersPaidAsMoneyArrives_CollateralBack` | Borrower repays 10,900 | Senior gets 6,300, junior 4,600, and all 10 ETH goes back |
| `test_PartialRepayment_GoesToSeniorFirst` | Borrower repays 6,000, then 1,000 | The first 6,300 goes to senior, only then junior |
| `test_DefaultUnanswered_SeniorThenJuniorThenBorrower` | Repays 3,000, claim, no answer | Senior 1.65 ETH, junior 2.30 ETH, borrower 6.05 ETH back |
| `test_CollateralTooSmall_SeniorTakesAll` | ETH worth only 500 POT | Senior takes all 10 ETH; junior takes the loss |
| `test_Dispute_PanelSaysPaidOffChain` | Borrower answers, 2 arbiters agree they paid | Loan repaid, ETH released, borrower wins both bonds |
| `test_Dispute_PanelConfirmsDefault` | 2 arbiters reject the answer | Default; claimant wins both bonds |
| `test_Dispute_NoQuorum_DefaultStands` | Votes split, time runs out | Default stands |
| `test_RepayDuringClaim_ClosesItAndReturnsBond` | Borrower pays in full after a claim | Claim closed, bond returned |
| `test_Cancel_RefundsAndReleases` | Loan never fully funded | Lender refunded, ETH released |
| `test_Vault_RejectsTamperedPayouts` | Someone redirects the borrower's ETH to themselves | Vault refuses |
| `test_Vault_RejectsWrongTotal_AndPaysOnce` | Payout doesn't add up; the same ruling sent twice | Both refused |
| `test_Lasso_RejectsProofFromWrongKey` | Collateral "proof" signed by the wrong key | Refused |
| `test_Lasso_RejectsCollateralLockedForAnotherLoan` | ETH locked for a different loan | Refused |
| `test_Lasso_RejectsWrongCollateralAmount` | 9 ETH locked instead of 10 | Refused |
| `test_Lasso_NoFundingBeforeProof_NoWrongAmount_NoSelfFunding` | Funding too early, wrong amount, borrower funding itself | All refused |
| `test_Lasso_ClaimRules` | Claim too early, by a stranger, without a bond | All refused |
| `test_Lasso_VoteRules` | A stranger votes, an arbiter votes twice, voting too late | All refused |
| `test_Lasso_LateAnswerRejected` | Borrower answers after the window | Refused |
| `test_Lasso_CannotOverpay` | Borrower sends more than owed | Refused |
| `testFuzz_DefaultPayoutsSumToCollateral` | 256 random loans, repayments and prices | Every ruling pays out **exactly** the locked ETH, and the vault accepts it |

### 4. Run the full story demo

This replays the whole default story against copies of the **live** chains, using the **real deployed contracts**.

**Start two local copies** (leave this terminal open):
```bash
anvil --fork-url https://test-evm-rpc-v3.portaldot.dev --port 8545 &
anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com --port 8546 &
```

**Run the demo** in a second terminal. It needs the key the contracts were deployed with, because that key is the temporary road's signer. If you aren't the deployer, deploy your own copy first (see below).
```bash
ATTESTER_KEY=0x<deployer key> ./demo/run-demo.sh
```

What you should see, step by step:
1. A loan of 10 POT is requested on Portaldot (6 senior at 5%, 4 junior at 15%), backed by 1 ETH.
2. 1 ETH is locked in the vault on Ethereum.
3. Road In: Lasso accepts proof of the lock.
4. Both lenders fund; the borrower receives 10 POT.
5. The borrower repays 3 POT. It all goes to the senior lender.
6. Time passes; the senior lender files a claim with a bond.
7. No answer; the default stands. The ruling is **senior 0.165 ETH, junior 0.23 ETH, borrower 0.605 ETH**.
8. Road Out: the vault pays exactly that on Ethereum. Sending the same ruling again is **refused**.

### 5. Deploy your own copy (optional)

Put `DEPLOYER_PRIVATE_KEY`, `ARBITER0_ADDRESS`, `ARBITER1_ADDRESS` and `ARBITER2_ADDRESS` in a `.env` file. Then:
```bash
set -a; . ./.env; set +a
forge script script/Deploy.s.sol:DeploySepolia --rpc-url sepolia --broadcast
```

On Portaldot, send the deploy with the exact gas estimate (no padding), or the node rejects it. You'll need about **490 POT** for the storage deposit:
```bash
forge script script/Deploy.s.sol:DeployPortaldot --rpc-url portaldot --broadcast --legacy --gas-estimate-multiplier 100
```

## Repository

| Path | What |
|---|---|
| [`src/Lasso.sol`](src/Lasso.sol) | Portaldot side |
| [`src/LassoVault.sol`](src/LassoVault.sol) | Ethereum side |
| [`src/libraries/Commitments.sol`](src/libraries/Commitments.sol) | The two cross-chain messages, hashed the same way on both chains |
| [`src/roads/AttestedRoad.sol`](src/roads/AttestedRoad.sol), [`src/interfaces/IRoads.sol`](src/interfaces/IRoads.sol) | The temporary road, and the interface the ZK road will plug into |
| [`test/Lasso.t.sol`](test/Lasso.t.sol) | 21 tests |
| [`demo/run-demo.sh`](demo/run-demo.sh) | The full story, scripted |
| [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploy scripts |

## Third-party code

- [forge-std](https://github.com/foundry-rs/forge-std) (MIT / Apache-2.0): tests and scripts only, not deployed.
- [Foundry](https://github.com/foundry-rs/foundry) (`forge`, `cast`, `anvil`): build, test, deploy, local forks.

## License

MIT
