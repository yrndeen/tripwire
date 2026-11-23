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

get_block_number() {
  local rpc="$1"
  local tx="$2"
  cast receipt "$tx" --rpc-url "$rpc" --json | python3 -c "
import sys, json
r = json.load(sys.stdin)
bn = r.get('blockNumber')
print(int(bn, 16) if isinstance(bn, str) and str(bn).startswith('0x') else int(bn))
"
}

get_block_ts() {
  local rpc="$1"
  local tx="$2"
  local bn
  bn=$(get_block_number "$rpc" "$tx")
  # Prefer --field timestamp; Foundry's --json wrapper may omit it.
  cast block "$bn" --rpc-url "$rpc" --field timestamp
}

fmt_ts() {
  python3 -c "from datetime import datetime, timezone, timedelta; ts=int('$1'); et=timezone(timedelta(hours=-5)); print(datetime.fromtimestamp(ts, timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC') + ' / ' + datetime.fromtimestamp(ts, et).strftime('%Y-%m-%d %I:%M:%S %p ET'))"
}

T_ORIGIN=$(get_block_ts "$UNICHAIN_RPC" "$ORIGIN_TX")
T_REACTIVE=$(get_block_ts "$LASNA_RPC" "$REACTIVE_TX")
T_CALLBACK=$(get_block_ts "$UNICHAIN_RPC" "$CALLBACK_TX")

HOP1=$((T_REACTIVE - T_ORIGIN))
HOP2=$((T_CALLBACK - T_REACTIVE))
TOTAL=$((T_CALLBACK - T_ORIGIN))

HOP1S="${HOP1}s"
HOP2S="${HOP2}s"
if [ "$HOP1" -lt 0 ]; then
  HOP1S="${HOP1}s (chain clock skew)"
fi

cat <<TABLE
| Stage | Chain | Tx Hash | Block Timestamp | Delta |
| --- | --- | --- | --- | --- |
| Origin Swap (\`PriceUpdated\`) | Unichain Sepolia (1301) | \`${ORIGIN_TX}\` | $(fmt_ts "$T_ORIGIN") (\`${T_ORIGIN}\`) | 0s |
| Reactive Evaluation (\`react\`) | Reactive Lasna (5318007) | \`${REACTIVE_TX}\` | $(fmt_ts "$T_REACTIVE") (\`${T_REACTIVE}\`) | ${HOP1S} |
| Destination Unwind (\`executeOrder\`) | Unichain Sepolia (1301) | \`${CALLBACK_TX}\` | $(fmt_ts "$T_CALLBACK") (\`${T_CALLBACK}\`) | ${HOP2S} (**Total: ${TOTAL}s**) |
TABLE
