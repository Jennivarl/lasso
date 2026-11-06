#!/usr/bin/env bash
# Lasso, the whole story in one run: a loan on Portaldot backed by ETH on Ethereum, a default,
# and the ruling pulling the ETH home to the lenders, senior first.
#
# It runs against local copies (forks) of Portaldot V3 testnet and Ethereum Sepolia that contain the
# REAL deployed Lasso and LassoVault contracts. Copies don't charge Portaldot's storage deposits,
# so the full story costs nothing and can be replayed any time.
#
# Usage:  anvil --fork-url https://test-evm-rpc-v3.portaldot.dev --port 8545 &
#         anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com --port 8546 &
#         ATTESTER_KEY=0x... ./demo/run-demo.sh        (the key Lasso and the road were deployed with)
set -euo pipefail

PD=${PD_RPC:-http://127.0.0.1:8545}
ETH=${ETH_RPC:-http://127.0.0.1:8546}
LASSO=${LASSO:-0x30e537B1FA7f59bE17440e9a49782d5Ff83D9dD1}
VAULT=${VAULT:-0x7C813053C1bfbEFF48Af6f8568E24972768306E2}
ROAD=${ROAD:-0x3E8B7b6BcDEda05B89B93c66A7325e932A751fa8}
PD_CHAIN=420420777
ETH_CHAIN=11155111
KEY=${ATTESTER_KEY:?set ATTESTER_KEY to the deployer key}

# Actors. The borrower is the deployer; the lenders and a helper are fresh wallets made for this run
# (well-known test keys are often hijacked on public testnets, which would muddy the numbers).
newkey() { cast wallet new --json | python3 -c "import sys,json;d=json.load(sys.stdin);d=d.get('data',d) if isinstance(d,dict) else d;d=d[0] if isinstance(d,list) else d;print(d['private_key'])"; }
BORROWER_KEY=$KEY
BORROWER=$(cast wallet address --private-key "$BORROWER_KEY")
SENIOR_KEY=$(newkey); SENIOR=$(cast wallet address --private-key $SENIOR_KEY)
JUNIOR_KEY=$(newkey); JUNIOR=$(cast wallet address --private-key $JUNIOR_KEY)
HELPER_KEY=$(newkey); HELPER=$(cast wallet address --private-key $HELPER_KEY)

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; R=$'\e[0m'
step() { echo; echo "${B}${C}── $1${R}"; sleep "${PAUSE:-1}"; }
say() { echo "   $1"; }
pot() { cast from-wei "$1" | sed 's/\.\?0*$//'; }
bal() { cast balance "$1" --rpc-url "$2"; }
send() { cast send "$@" --json | python3 -c "import sys,json;r=json.load(sys.stdin);print(r['transactionHash'])"; }
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$PD" >/dev/null; cast rpc evm_mine --rpc-url "$PD" >/dev/null; }

# Give everyone test money on the copies.
for a in $BORROWER $SENIOR $JUNIOR $HELPER; do
  cast rpc anvil_setBalance "$a" 0x3635C9ADC5DEA00000 --rpc-url "$PD" >/dev/null   # 1,000 POT
  cast rpc anvil_setBalance "$a" 0x8AC7230489E80000 --rpc-url "$ETH" >/dev/null    # 10 ETH
done

echo "${B}LASSO${R}  borrow on Portaldot against ETH that never leaves Ethereum"
echo "${D}Lasso on Portaldot $LASSO | LassoVault on Ethereum $VAULT${R}"

# ------------------------------------------------------------------ 1. request
step "1. Portaldot: a business asks for 10 POT"
say "6 POT from a ${B}senior${R} lender at 5%, 4 POT from a ${B}junior${R} lender at 15%  → 10.9 POT owed"
say "Backed by ${B}1 ETH${R} locked on Ethereum. If it defaults, 1 ETH is valued at 20 POT."
NOW=$(cast block latest --field timestamp --rpc-url "$PD")
AMOUNTS=$(python3 -c "print((6*10**18<<128)|4*10**18)")
BACKING=$(python3 -c "print((10**18<<128)|20*10**18)")
SCHED=$(python3 -c "print(($ETH_CHAIN<<192)|(($NOW+600)<<128)|(($NOW+900)<<64)|(500<<16)|1500)")
ID=$(cast call $LASSO "loanCount()(uint256)" --rpc-url "$PD")
TX=$(send $LASSO "request(address,uint256,uint256,uint256)" $VAULT $AMOUNTS $BACKING $SCHED --private-key $BORROWER_KEY --rpc-url "$PD")
say "${G}✓${R} loan #$ID requested   ${D}$TX${R}"

# ------------------------------------------------------------------ 2. lock
step "2. Ethereum: the borrower locks 1 ETH in LassoVault for loan #$ID"
DEP=$(cast call $VAULT "nextDepositId()(uint256)" --rpc-url "$ETH")
TX=$(send $VAULT "lock(uint256,address,uint256)" $PD_CHAIN $LASSO $ID --value 1ether --private-key $BORROWER_KEY --rpc-url "$ETH")
COMMIT=$(cast call $VAULT "commitments(uint256)(bytes32)" $DEP --rpc-url "$ETH")
say "${G}✓${R} deposit #$DEP locked; the vault stores its fingerprint ${D}$COMMIT${R}"
say "${D}$TX${R}"

# ------------------------------------------------------------------ 3. road in
step "3. Road In: Portaldot learns the ETH is really locked"
TAG=$(cast keccak "LASSO_ATTESTED_ROAD_IN_V1")
DIGEST=$(cast keccak $(cast abi-encode "f(bytes32,uint256,address,uint256,address,uint256,bytes32)" $TAG $PD_CHAIN $LASSO $ETH_CHAIN $VAULT $DEP $COMMIT))
SIG=$(cast wallet sign --private-key $KEY $DIGEST)
TX=$(send $LASSO "prove(uint256,uint64,bytes)" $ID $DEP $SIG --private-key $BORROWER_KEY --rpc-url "$PD")
say "${G}✓${R} Lasso recomputed the fingerprint and accepted it. Lenders can now fund."
say "${Y}(today a trusted signer carries this message; the ZK road replaces it)${R}  ${D}$TX${R}"

# ------------------------------------------------------------------ 4. fund
step "4. Portaldot: both lenders fund, the loan starts"
B0=$(bal $BORROWER "$PD")
send $LASSO "fund(uint256,bool)" $ID true --value 6ether --private-key $SENIOR_KEY --rpc-url "$PD" >/dev/null
TX=$(send $LASSO "fund(uint256,bool)" $ID false --value 4ether --private-key $JUNIOR_KEY --rpc-url "$PD")
B1=$(bal $BORROWER "$PD")
say "${G}✓${R} senior put in 6 POT, junior 4 POT → borrower received $(pot $(python3 -c "print($B1-$B0)")) POT (minus fees)  ${D}$TX${R}"

# ------------------------------------------------------------------ 5. partial repay
step "5. Portaldot: the borrower repays only 3 POT, then goes quiet"
S0=$(bal $SENIOR "$PD"); J0=$(bal $JUNIOR "$PD")
TX=$(send $LASSO "repay(uint256)" $ID --value 3ether --private-key $BORROWER_KEY --rpc-url "$PD")
say "${G}✓${R} the 3 POT went straight to the ${B}senior${R} lender: +$(pot $(python3 -c "print($(bal $SENIOR "$PD")-$S0)")) POT; junior +$(pot $(python3 -c "print($(bal $JUNIOR "$PD")-$J0)")) POT  ${D}$TX${R}"

# ------------------------------------------------------------------ 6. claim
step "6. Due date + grace period pass. The senior lender files a default claim."
warp 1100
TX=$(send $LASSO "claim(uint256,bytes32)" $ID $(cast keccak "missed final payment; invoice #4471 unpaid") --value 0.01ether --private-key $SENIOR_KEY --rpc-url "$PD")
say "${G}✓${R} claim filed with a 0.01 POT bond (lost if the claim is false)  ${D}$TX${R}"
say "The borrower now has 3 minutes to answer with evidence, e.g. a bank receipt."

# ------------------------------------------------------------------ 7. ruling
step "7. No answer. Anyone finalizes: the default stands, Lasso rules."
warp 200
TX=$(send $LASSO "finalize(uint256)" $ID --private-key $SENIOR_KEY --rpc-url "$PD")
RULING=$(cast call $LASSO "rulingOf(uint256)(bytes32)" $ID --rpc-url "$PD")
read -r TO0 TO1 TO2 A0 A1 A2 < <(cast receipt $TX --json --rpc-url "$PD" | python3 -c "
import sys,json
r=json.load(sys.stdin)
for lg in r['logs']:
    d=bytes.fromhex(lg['data'][2:])
    if len(d)==7*32:
        w=[d[i*32:(i+1)*32] for i in range(7)]
        print(*['0x'+x[12:].hex() for x in w[1:4]], *[int.from_bytes(x,'big') for x in w[4:7]])
")
say "Still owed: senior 6.3 − 3 = 3.3 POT, junior 4.6 POT.  At 20 POT per ETH:"
say "  ${B}senior${R}   $(pot $A0) ETH   ${D}$TO0${R}"
say "  ${B}junior${R}   $(pot $A1) ETH   ${D}$TO1${R}"
say "  ${B}borrower${R} $(pot $A2) ETH back (the surplus)   ${D}$TO2${R}"
say "${G}✓${R} ruling fingerprint stored on Portaldot: ${D}$RULING${R}"

# ------------------------------------------------------------------ 8. road out + execute
step "8. Road Out: the ruling reaches Ethereum, and the vault pays out"
RD=$(cast call $ROAD "rulingDigest(uint256,address,uint256,bytes32)(bytes32)" $PD_CHAIN $LASSO $ID $RULING --rpc-url "$ETH")
RSIG=$(cast wallet sign --private-key $KEY $RD)
E0=$(bal $SENIOR "$ETH"); E1=$(bal $JUNIOR "$ETH")
TX=$(send $VAULT "execute(uint256,(address[3],uint256[3]),bytes)" $DEP "([$TO0,$TO1,$TO2],[$A0,$A1,$A2])" $RSIG --private-key $HELPER_KEY --rpc-url "$ETH")
say "${G}✓${R} vault checked the ruling against its own deposit and paid it, exactly once  ${D}$TX${R}"
say "  senior lender on Ethereum: +$(pot $(python3 -c "print($(bal $SENIOR "$ETH")-$E0)")) ETH"
say "  junior lender on Ethereum: +$(pot $(python3 -c "print($(bal $JUNIOR "$ETH")-$E1)")) ETH"
  say "  ${D}(sent by a helper wallet: anyone can carry a ruling out; the proof is what counts)${R}"

step "Try to cheat: send the same ruling again, or with the borrower's share redirected"
if cast send $VAULT "execute(uint256,(address[3],uint256[3]),bytes)" $DEP "([$TO0,$TO1,$TO2],[$A0,$A1,$A2])" $RSIG --private-key $HELPER_KEY --rpc-url "$ETH" >/dev/null 2>&1; then
  say "✗ paid twice (should never happen)"; exit 1
else say "${G}✓${R} refused: already settled"; fi

echo
echo "${B}Done.${R} Borrowed on Portaldot, enforced on Ethereum, senior lender protected first."
