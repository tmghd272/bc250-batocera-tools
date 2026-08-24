#!/bin/bash
# test-8core.sh -- correctness + load probe for the BC-250's unlocked cores.
# Each core runs an identical SHA-256 chain; a bad core diverges or crashes.
# Cores 3 and 7 are the ones the unlock enables. Pins via python (no taskset).
set -u

ITERS="${1:-400000}"
PY=$(command -v python3 || command -v python)
[ -n "$PY" ] || { echo "error: python not found"; exit 1; }

PROBE=/tmp/bc250-core-probe.py
cat > "$PROBE" << 'PYEOF'
import hashlib, os, sys
cpu = int(sys.argv[1]); iters = int(sys.argv[2])
try:
    os.sched_setaffinity(0, {cpu})
except Exception as e:
    sys.stderr.write("affinity failed: %s\n" % e); sys.exit(2)
h = b"BC250-verify"
for _ in range(iters):
    h = hashlib.sha256(h).digest()
print(h.hex())
PYEOF

# first logical CPU of each physical core
declare -A CPU_OF_CORE
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    n=${c##*/cpu}
    id=$(cat "$c/topology/core_id" 2>/dev/null) || continue
    [ -n "${CPU_OF_CORE[$id]:-}" ] || CPU_OF_CORE[$id]=$n
done
CORES=$(printf '%s\n' "${!CPU_OF_CORE[@]}" | sort -n)
NCORES=$(echo "$CORES" | wc -l)
echo "physical cores detected: $NCORES"
echo "hash-chain iterations per core: $ITERS"
echo

mce_before=$(dmesg 2>/dev/null | grep -icE 'machine check exception|mce:.*error|hardware error')

echo "=== per-core deterministic hash chain (all must match) ==="
REF=""; FAILED=""
for core in $CORES; do
    cpu=${CPU_OF_CORE[$core]}
    res=$("$PY" "$PROBE" "$cpu" "$ITERS" 2>/dev/null)
    tag=""; case $core in 3|7) tag=" <-- NEW";; esac
    if [ -z "$res" ]; then
        printf "  core %s (cpu%-2s): <no output>  ERROR%s\n" "$core" "$cpu" "$tag"; FAILED="$FAILED $core"; continue
    fi
    [ -z "$REF" ] && REF="$res"
    if [ "$res" = "$REF" ]; then
        printf "  core %s (cpu%-2s): %s  OK%s\n" "$core" "$cpu" "${res:0:16}" "$tag"
    else
        printf "  core %s (cpu%-2s): %s  MISMATCH!!%s\n" "$core" "$cpu" "${res:0:16}" "$tag"; FAILED="$FAILED $core"
    fi
done
echo "  reference digest: ${REF:0:16}"
echo

echo "=== heavy all-thread load ($(nproc) threads) ==="
pids=""
NCPU=$(nproc)
for cpu in $(seq 0 $((NCPU-1))); do
    "$PY" "$PROBE" "$cpu" "$ITERS" >/dev/null 2>&1 &
    pids="$pids $!"
done
sleep 2
TEMP=$(for f in /sys/class/hwmon/hwmon*/temp1_input; do [ -f "$f" ] && awk '{printf "%.0f",$1/1000}' "$f" && break; done 2>/dev/null)
wait $pids
echo "  all-thread run complete (mid-load temp: ${TEMP:-?}C)"
echo

mce_after=$(dmesg 2>/dev/null | grep -icE 'machine check exception|mce:.*error|hardware error')
echo "=== machine-check errors (real) ==="
echo "  before: $mce_before   after: $mce_after"
echo

if [ -n "$FAILED" ] || [ "$mce_after" -gt "$mce_before" ]; then
    echo "RESULT: FAIL -- core(s):$FAILED bad, or MCEs appeared. Cold-boot to revert to 6c."
    exit 1
else
    echo "RESULT: PASS -- all $NCORES cores compute identically, no MCEs."
    echo "        (Still validate with a real multi-hour game session before trusting fully.)"
    exit 0
fi
