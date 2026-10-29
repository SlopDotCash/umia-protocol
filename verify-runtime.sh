#!/usr/bin/env bash
# Verify a contract deployed at RUNTIME (CLI/TGE flows, not forge broadcasts):
# fetches the creation tx from Basescan, derives the constructor args by
# stripping the local artifact's creation bytecode off the tx input, then
# submits via verify-fixed.sh (which fixes the remapping-metadata drift).
#
# Usage: ./verify-runtime.sh <address> <path:Name> [extra forge args...]
set -euo pipefail
cd "$(dirname "$0")"
ADDR=$1; FQN=$2; shift 2
SRC=${FQN%%:*}; NAME=${FQN##*:}
ART="out/$(basename "$SRC")/$NAME.json"
[ -f "$ART" ] || { echo "artifact $ART not found; run forge build"; exit 1; }

TXHASH=$(curl -s "https://api.etherscan.io/v2/api?chainid=8453&module=contract&action=getcontractcreation&contractaddresses=$ADDR&apikey=$ETHERSCAN_API_KEY" | jq -r '.result[0].txHash')
[ "$TXHASH" != "null" ] || { echo "no creation tx found for $ADDR"; exit 1; }
INPUT=$(curl -s "https://api.etherscan.io/v2/api?chainid=8453&module=proxy&action=eth_getTransactionByHash&txhash=$TXHASH&apikey=$ETHERSCAN_API_KEY" | jq -r '.result.input')

CODE=$(jq -r '.bytecode.object' "$ART" | sed 's/^0x//')
IN=${INPUT#0x}
CTOR=""
case "$IN" in
  "$CODE"*) CTOR=${IN#"$CODE"} ;;   # direct EOA deploy: input = creationCode ++ args
  *)
      REST=${IN#*"$CODE"}
      [ "$REST" = "$IN" ] && { echo "local bytecode not found in creation tx (build drift?)"; exit 1; }
      echo "factory deploy: trailing calldata after embedded creation code:"
      printf '%s\n' "$REST" | head -c 512; echo
      CTOR=$REST
      ;;
esac
echo "ctor args: ${CTOR:-<none>} (${#CTOR} hex chars)"
exec ./verify-fixed.sh "$ADDR" "$FQN" "$CTOR" "$@"
