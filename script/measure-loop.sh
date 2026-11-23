#!/usr/bin/env bash
# Read-only latency measurement helper for Tripwire full-loop runs.
# Usage: ./script/measure-loop.sh <origin_tx> <reactive_tx> <callback_tx>
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <unichain_origin_tx> <lasna_reactive_tx> <unichain_callback_tx>" >&2
  exit 1
fi

ORIGIN_TX="$1"
REACTIVE_TX="$2"
CALLBACK_TX="$3"

UNICHAIN_RPC="${UNICHAIN_SEPOLIA_RPC:-https://sepolia.unichain.org}"
LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev/}"

get_block_ts() {
  local rpc="$1"
  local tx="$2"
  local bn
  bn=$(cast receipt "$tx" --rpc-url "$rpc" --json | python3 -c "import sys,json; print(int(json.load(sys.stdin)['blockNumber'], 16))")
  cast block "$bn" --rpc-url "$rpc" --json | python3 -c "import sys,json; print(int(json.load(sys.stdin)['timestamp'], 16))"
}

T_ORIGIN=$(get_block_ts "$UNICHAIN_RPC" "$ORIGIN_TX")
T_REACTIVE=$(get_block_ts "$LASNA_RPC" "$REACTIVE_TX")
T_CALLBACK=$(get_block_ts "$UNICHAIN_RPC" "$CALLBACK_TX")

HOP1=$((T_REACTIVE - T_ORIGIN))
HOP2=$((T_CALLBACK - T_REACTIVE))
TOTAL=$((T_CALLBACK - T_ORIGIN))

cat <<TABLE
| Stage | Chain | Tx Hash | Block Timestamp (UTC) | Delta |
| --- | --- | --- | --- | --- |
| Origin Swap (\`PriceUpdated\`) | Unichain Sepolia (1301) | \`${ORIGIN_TX}\` | ${T_ORIGIN} | 0s |
| Reactive Evaluation (\`react\`) | Reactive Lasna (5318007) | \`${REACTIVE_TX}\` | ${T_REACTIVE} | +${HOP1}s |
| Destination Unwind (\`executeOrder\`) | Unichain Sepolia (1301) | \`${CALLBACK_TX}\` | ${T_CALLBACK} | +${HOP2}s (**Total: ${TOTAL}s**) |
TABLE
