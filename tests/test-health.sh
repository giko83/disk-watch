#!/usr/bin/env bash
# Offline fixture coverage: neither real disks nor journald nor Telegram touched.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/smartctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SMART_CALL_LOG"
case "$SMART_SCENARIO" in
nvme)
 cat <<'TEXT'
Model Number:                       Sample NVMe
Serial Number:                      NVME-TEST-0001
SMART overall-health self-assessment test result: PASSED
Temperature:                        40 Celsius
Percentage Used:                    12%
Data Units Written:                 2,000 [1.02 GB]
Power On Hours:                     100
Media and Data Integrity Errors:    0
Self-test status: Extended self-test in progress (13% completed)
TEXT
 exit 8 ;;
ata)
 cat <<'TEXT'
Device Model:     ATA test disk
Serial Number:    ATA-TEST-0002
SMART overall-health self-assessment test result: PASSED
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  9 Power_On_Hours          0x0032   098   098   000    Old_age   Always       -       4512
194 Temperature_Celsius     0x0022   101   100   000    Old_age   Always       -       37
197 Current_Pending_Sector  0x0012   100   100   000    Old_age   Always       -       3
TEXT
 ;;
fail)
 echo 'smartctl: device not found' >&2
 exit 2 ;;
*)
 echo 'unexpected scenario' >&2; exit 3;;
esac
MOCK
chmod +x "$TMP/bin/smartctl"
export PATH="$TMP/bin:$PATH" SMART_CALL_LOG="$TMP/calls" SMART_SCENARIO=nvme
script="$ROOT/disk-watch.sh"
st="$TMP/state folder"
# All default commands must work without config or SMART calls and without
# creating state when none exists.
bash "$script" status --state-dir "$st" > "$TMP/output"
grep -Fq 'SMART history: unavailable' "$TMP/output" || fail 'empty history diagnostic missing'
bash "$script" health --state-dir "$st" > "$TMP/output"
[[ ! -e "$TMP/calls" && ! -d "$st" ]] || fail 'cached report unexpectedly probed disk or wrote state'
# A read request that specifies a device must not trigger a probe.
bash "$script" history --device NVME-TEST-0001 --state-dir "$st" >/dev/null
[[ ! -e "$TMP/calls" ]] || fail 'history unexpectedly ran smartctl'
# Explicit opt-in is mandatory before any device access.
if bash "$script" health --device /dev/null --refresh --state-dir "$st" >"$TMP/output" 2>&1; then fail 'SMART refresh accepted without wake-ok'; fi
if bash "$script" health --device /dev/null --wake-ok --state-dir "$st" >"$TMP/output" 2>&1; then fail 'SMART wake-ok accepted without refresh'; fi
[[ ! -e "$TMP/calls" ]] || fail 'unsafe option path invoked smartctl'
# Mock NVMe test with SMART failing exit bits despite useful data.
bash "$script" health --device /dev/null --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/calls") -eq 1 ]] || fail 'expected one explicit SMART invocation'
grep -Fq 'NVME-TEST-0001' "$TMP/out" || fail 'missing NVMe serial'
grep -Fq $'\tpassed\t40\t100\tunavailable\tunavailable\t0\t1.02\t12\tin_progress' "$TMP/out" || fail 'missing or incorrect NVMe metrics'
[[ -s "$st/health/snapshots.tsv" ]] || fail 'snapshot not saved'
# Cached CLI never runs smartctl, including health with --device but no refresh.
bash "$script" disks --state-dir "$st" > "$TMP/out"
bash "$script" health --device /dev/null --state-dir "$st" > "$TMP/out"
bash "$script" status --state-dir "$st" > "$TMP/out"
grep -Fq 'Last alert: unavailable' "$TMP/out" || fail 'missing explicit unavailable alert status'
grep -Fq 'Snapshots: 1' "$TMP/out" || fail 'snapshot count wrong'
[[ $(wc -l < "$TMP/calls") -eq 1 ]] || fail 'cached command ran smartctl'
# Add a second drive, verify history filtering, unavailable fields and date range.
export SMART_SCENARIO=ata
bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
grep -Fq $'ATA-TEST-0002\tATA test disk\tpassed\t37\t4512\tunavailable\t3' "$TMP/out" || fail 'ATA parsing wrong'
bash "$script" disks --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 3 ]] || fail 'inventory should contain header plus two disks'
bash "$script" health --device NVME-TEST-0001 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 2 ]] || fail 'cached health filter did not select one disk'
bash "$script" history --device NVME-TEST-0001 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 2 ]] || fail 'serial filter failed'
bash "$script" history --device /dev/zero --state-dir "$st" --format tsv > "$TMP/out"
grep -Fq 'ATA-TEST-0002' "$TMP/out" || fail 'device-path filter failed'
bash "$script" report --since 2999-01-01 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 1 ]] || fail 'future since filter failed'
bash "$script" report --since 2000-01-01 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 3 ]] || fail 'past since filter failed'
export SMART_SCENARIO=fail
if bash "$script" health --device /dev/null --refresh --wake-ok --state-dir "$st" > "$TMP/out" 2>&1; then fail 'unreadable SMART report was accepted'; fi
[[ $(wc -l < "$st/health/snapshots.tsv") -eq 3 ]] || fail 'failed SMART probe wrote snapshot'
[[ $(wc -l < "$TMP/calls") -eq 3 ]] || fail 'unexpected probe count'
echo 'PASS: offline cached health, explicit wake guard, NVMe/ATA metrics, history, device filters, report and failures'
