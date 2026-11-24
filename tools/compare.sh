#!/usr/bin/env bash
# compare.sh - compare GP5 (local) against a reference Apothem RPC
# Usage: tools/compare.sh [samples] [local_rpc] [reference_rpc]
# Example: ./gp5.sh compare 50
# Needs: curl, jq

SAMPLES=${1:-30}
LOCAL=${2:-http://127.0.0.1:8545}
REF=${3:-https://rpc.apothem.network}

rpc() { # url method params
  curl -s -m 20 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":$3,\"id\":1}" "$1"
}
lc() { tr '[:upper:]' '[:lower:]'; }

mkdir -p "$(dirname "$0")/../logs"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf "  PASS  %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; echo "$1" >> "$(dirname "$0")/../logs/compare-failures.log"; }
skip() { SKIP=$((SKIP+1)); printf "  SKIP  %s\n" "$1"; }

echo "== Basic checks =="
CID=$(rpc "$LOCAL" eth_chainId '[]' | jq -r .result)
[ "$CID" = "0x33" ] && ok "chainId = 0x33 (51)" || bad "chainId = $CID (expected 0x33)"

HEAD_HEX=$(rpc "$LOCAL" eth_blockNumber '[]' | jq -r .result)
HEAD=$((HEAD_HEX))
REF_HEAD=$(( $(rpc "$REF" eth_blockNumber '[]' | jq -r .result) ))
echo "  local head: $HEAD   reference head: $REF_HEAD"
[ "$HEAD" -gt 0 ] || { echo "Local node not answering"; exit 1; }

echo "== Block comparison ($SAMPLES random blocks + epoch/checkpoint blocks) =="
BLOCKS=()
for _ in $(seq 1 "$SAMPLES"); do BLOCKS+=( $(( (RANDOM * 32768 + RANDOM) % HEAD + 1 )) ); done
# XDPoS epoch boundaries (900 blocks) and the block just before them
for e in 900 1800 $(( (HEAD/900)*900 )) $(( (HEAD/2/900)*900 )); do
  [ "$e" -le "$HEAD" ] && BLOCKS+=( "$e" $((e-1)) )
done

for B in "${BLOCKS[@]}"; do
  H=$(printf '0x%x' "$B")
  L=$(rpc "$LOCAL" eth_getBlockByNumber "[\"$H\",false]")
  R=$(rpc "$REF"   eth_getBlockByNumber "[\"$H\",false]")
  if [ "$(echo "$R" | jq -r .result)" = "null" ] || [ -z "$R" ]; then skip "block $B (reference RPC gave no data)"; continue; fi
  DIFF=""
  for f in hash parentHash stateRoot transactionsRoot receiptsRoot miner gasUsed; do
    lv=$(echo "$L" | jq -r ".result.$f" | lc); rv=$(echo "$R" | jq -r ".result.$f" | lc)
    [ "$lv" != "$rv" ] && DIFF="$DIFF $f(local=$lv ref=$rv)"
  done
  ltx=$(echo "$L" | jq '.result.transactions|length'); rtx=$(echo "$R" | jq '.result.transactions|length')
  [ "$ltx" != "$rtx" ] && DIFF="$DIFF txcount(local=$ltx ref=$rtx)"
  [ -z "$DIFF" ] && ok "block $B" || bad "block $B:$DIFF"

  # Receipt check on the first transaction, if any
  TX=$(echo "$R" | jq -r '.result.transactions[0] // empty')
  if [ -n "$TX" ]; then
    LR=$(rpc "$LOCAL" eth_getTransactionReceipt "[\"$TX\"]")
    RR=$(rpc "$REF"   eth_getTransactionReceipt "[\"$TX\"]")
    if [ "$(echo "$LR" | jq -r .result)" = "null" ]; then
      bad "receipt $TX (block $B): missing on GP5 (tx index lag?)"
    else
      RD=""
      for f in status gasUsed cumulativeGasUsed contractAddress; do
        lv=$(echo "$LR" | jq -r ".result.$f" | lc); rv=$(echo "$RR" | jq -r ".result.$f" | lc)
        [ "$lv" != "$rv" ] && RD="$RD $f(local=$lv ref=$rv)"
      done
      ll=$(echo "$LR" | jq '.result.logs|length'); rl=$(echo "$RR" | jq '.result.logs|length')
      [ "$ll" != "$rl" ] && RD="$RD logs(local=$ll ref=$rl)"
      [ -z "$RD" ] && ok "receipt in block $B" || bad "receipt $TX (block $B):$RD"
    fi
  fi
done

echo "== RPC modules exposed by GP5 =="
rpc "$LOCAL" rpc_modules '[]' | jq -c .result

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && echo "Failures saved to logs/compare-failures.log"
