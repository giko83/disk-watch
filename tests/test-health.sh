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
scsi_usb)
 cat <<'TEXT'
Vendor:                         Example
Product:                        USB/SCSI bridge
Serial number:                  USB-SCSI-0003   
LU WWN Device Id:               5 000cca 999999999
SMART Health Status:            OK
TEXT
 ;;
scsi_no_serial)
 cat <<'TEXT'
Product:                        USB bridge without exposed serial
SMART Health Status:            OK
TEXT
 ;;
ata_wwn)
 cat <<'TEXT'
Device Model:                   ATA drive without serial
LU WWN Device Id:               5 000cca 123456789
SMART overall-health self-assessment test result: PASSED
TEXT
 ;;
wwn_compact)
 cat <<'TEXT'
Device Model:                   Same drive, changed /dev path
WWN Device Id:                  5000CCA123456789
SMART overall-health self-assessment test result: PASSED
TEXT
 ;;
wwn_invalid)
 cat <<'TEXT'
Device Model:                   Drive with malformed WWN
LU WWN Device Id:               5 000cca 12345678g
SMART overall-health self-assessment test result: PASSED
TEXT
 ;;
placeholder_serial_wwn)
 cat <<'TEXT'
Device Model:                   USB bridge with placeholder serial
Serial number:                  UNKNOWN
LU WWN Device Id:               5 000cca 555555555
SMART Health Status:            OK
TEXT
 ;;
placeholder_serial_no_wwn)
 cat <<'TEXT'
Product:                        USB bridge without stable ID
Serial Number:                  N/A
SMART Health Status:            OK
TEXT
 ;;
zero_wwn)
 cat <<'TEXT'
Device Model:                   Drive with all-zero WWN
WWN Device Id:                  0000000000000000
SMART overall-health self-assessment test result: PASSED
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
# Synthetic SCSI/USB text uses a lowercase "number" label. Its firmware serial
# must be the cache ID, not the transient /dev path; missing metrics stay absent.
export SMART_SCENARIO=scsi_usb
bash "$script" health --device /dev/full --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$3=="USB-SCSI-0003" {if ($2!="/dev/full" || $4!="unavailable" || $5!="passed" || $6!="unavailable" || $11!="unavailable") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'SCSI/USB serial or unavailable metric parsing wrong'
bash "$script" history --device USB-SCSI-0003 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 2 ]] || fail 'SCSI/USB serial history filter failed'
# A bridge without a serial must still use the explicit path, never invent an ID.
export SMART_SCENARIO=scsi_no_serial
bash "$script" health --device /dev/random --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$2=="/dev/random" {if ($3!="/dev/random" || $4!="unavailable" || $5!="passed" || $6!="unavailable") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'missing serial should fall back to device path'
[[ $(wc -l < "$TMP/calls") -eq 5 ]] || fail 'unexpected USB mock probe count'
# A validated WWN supplies a stable cache ID when the firmware serial is absent.
# Two /dev paths and WWN label formats must map to the same history identity.
export SMART_SCENARIO=ata_wwn
bash "$script" health --device /dev/urandom --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$2=="/dev/urandom" {if ($3!="wwn:5000cca123456789" || $5!="passed") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'spaced LU WWN identity parsing failed'
export SMART_SCENARIO=wwn_compact
bash "$script" health --device /dev/tty --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
bash "$script" history --device wwn:5000cca123456789 --state-dir "$st" --format tsv > "$TMP/out"
[[ $(wc -l < "$TMP/out") -eq 3 ]] || fail 'same WWN on different paths should share history'
# Malformed WWNs must not become a guessed persistent identifier.
export SMART_SCENARIO=wwn_invalid
bash "$script" health --device /dev/null --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$4=="Drive with malformed WWN" {if ($2!="/dev/null" || $3!="/dev/null") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'malformed WWN should fall back to device path'
[[ $(wc -l < "$TMP/calls") -eq 8 ]] || fail 'unexpected WWN mock probe count'
# Placeholder serials are not unique identities: use a valid WWN if present,
# otherwise keep the explicit path. An all-zero WWN must not merge histories.
export SMART_SCENARIO=placeholder_serial_wwn
bash "$script" health --device /dev/stdin --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$4=="USB bridge with placeholder serial" {if ($3!="wwn:5000cca555555555") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'placeholder serial should defer to valid WWN'
export SMART_SCENARIO=placeholder_serial_no_wwn
bash "$script" health --device /dev/stdout --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$2=="/dev/stdout" {if ($3!="/dev/stdout") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'placeholder serial without WWN should use path'
export SMART_SCENARIO=zero_wwn
bash "$script" health --device /dev/stderr --refresh --wake-ok --state-dir "$st" --format tsv > "$TMP/out"
awk -F '\t' '$4=="Drive with all-zero WWN" {if ($3!="/dev/stderr") exit 1; found=1} END {if (!found) exit 1}' "$TMP/out" || fail 'all-zero WWN should not become shared identity'
[[ $(wc -l < "$TMP/calls") -eq 11 ]] || fail 'unexpected placeholder identity probe count'
# Reject unsafe snapshot paths before the SMART probe, not just before write.
# A symlinked lock must not truncate its target; a FIFO must not hang refresh.
mkdir -p "$TMP/redirected" "$TMP/health-linked-dir" "$TMP/health-linked-lock/health" \
  "$TMP/health-fifo-lock/health" "$TMP/health-linked-db/health"
ln -s "$TMP/redirected" "$TMP/health-linked-state"
ln -s "$TMP/redirected" "$TMP/health-linked-dir/health"
printf 'DO NOT TOUCH\n' > "$TMP/sentinel"
ln -s "$TMP/sentinel" "$TMP/health-linked-lock/health/.snapshots.lock"
ln -s "$TMP/sentinel" "$TMP/health-linked-db/health/snapshots.tsv"
mkfifo "$TMP/health-fifo-lock/health/.snapshots.lock"
probes_before=$(wc -l < "$TMP/calls")
export SMART_SCENARIO=ata
for bad in health-linked-state health-linked-dir health-linked-lock health-linked-db health-fifo-lock; do
  if bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$TMP/$bad" > "$TMP/out" 2>&1; then
    fail "unsafe snapshot storage $bad was accepted"
  fi
  grep -Fq 'Unsafe SMART snapshot storage path' "$TMP/out" ||
    fail "missing unsafe snapshot storage diagnostic for $bad"
done
[[ $(wc -l < "$TMP/calls") -eq "$probes_before" ]] || fail 'unsafe storage probed SMART hardware'
[[ $(cat "$TMP/sentinel") == 'DO NOT TOUCH' ]] || fail 'symlink target was changed'
[[ ! -e "$TMP/redirected/snapshots.tsv" ]] || fail 'symlinked directory received snapshot'
# Ancestors of the state directory must also be checked before SMART access.
# A symlinked parent is unsafe even when the state/health leaf is not linked.
mkdir -p "$TMP/ancestor-target"
ln -s "$TMP/ancestor-target" "$TMP/ancestor-link"
printf 'NOT A DIRECTORY\n' > "$TMP/ancestor-file"
for bad_state in "$TMP/ancestor-link/nested" "$TMP/ancestor-file/nested"; do
  if bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$bad_state" > "$TMP/out" 2>&1; then
    fail "unsafe ancestor $bad_state was accepted"
  fi
  grep -Fq 'Unsafe SMART snapshot storage path' "$TMP/out" ||
    fail "missing unsafe ancestor diagnostic for $bad_state"
done
[[ $(wc -l < "$TMP/calls") -eq "$probes_before" ]] || fail 'unsafe ancestor triggered SMART probe'
[[ ! -e "$TMP/ancestor-target/nested/health/snapshots.tsv" ]] || fail 'symlink ancestor received snapshot'
# Reject incompatible or unterminated snapshot headers before probing SMART.
# Existing bytes must remain intact: never silently mix history schemas.
bad_header_state="$TMP/health-invalid-header"
mkdir -p "$bad_header_state/health"
printf 'timestamp_utc\tdevice\tlegacy_id\n' > "$bad_header_state/health/snapshots.tsv"
cp "$bad_header_state/health/snapshots.tsv" "$TMP/bad-header-original"
probes_before=$(wc -l < "$TMP/calls")
if bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$bad_header_state" > "$TMP/out" 2>&1; then
  fail 'incompatible snapshot header was accepted'
fi
grep -Fq 'Incompatible SMART snapshot header' "$TMP/out" || fail 'missing incompatible header diagnostic'
cmp -s "$TMP/bad-header-original" "$bad_header_state/health/snapshots.tsv" || fail 'incompatible history was modified'
# A correct-looking header without its final newline is also unsafe to append.
printf '%s' "$(head -n 1 "$st/health/snapshots.tsv")" > "$bad_header_state/health/snapshots.tsv"
cp "$bad_header_state/health/snapshots.tsv" "$TMP/bad-header-original"
if bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$bad_header_state" > "$TMP/out" 2>&1; then
  fail 'unterminated snapshot header was accepted'
fi
grep -Fq 'Incompatible SMART snapshot header' "$TMP/out" || fail 'missing unterminated header diagnostic'
cmp -s "$TMP/bad-header-original" "$bad_header_state/health/snapshots.tsv" || fail 'unterminated history was modified'
[[ $(wc -l < "$TMP/calls") -eq "$probes_before" ]] || fail 'invalid snapshot header triggered SMART probe'
# Refuse damaged historical data rows as well as damaged headers. A truncated
# final line could otherwise be joined to a new snapshot during append.
bad_row_state="$TMP/health-invalid-rows"
mkdir -p "$bad_row_state/health"
valid_header=$(head -n 1 "$st/health/snapshots.tsv")
valid_row=$(sed -n '2p' "$st/health/snapshots.tsv")
probes_before=$(wc -l < "$TMP/calls")
for scenario in short extra blank-id unterminated; do
  printf '%s\n' "$valid_header" > "$bad_row_state/health/snapshots.tsv"
  case $scenario in
    short) printf '2026-10-29T12:00:00Z\t/dev/fake\n' >> "$bad_row_state/health/snapshots.tsv" ;;
    extra) printf '%s\textra\n' "$valid_row" >> "$bad_row_state/health/snapshots.tsv" ;;
    blank-id) printf '%s\n' "$valid_row" | awk -F '\t' 'BEGIN {OFS="\t"} {$3=""; print}' >> "$bad_row_state/health/snapshots.tsv" ;;
    unterminated) printf '%s' "$valid_row" >> "$bad_row_state/health/snapshots.tsv" ;;
  esac
  cp "$bad_row_state/health/snapshots.tsv" "$TMP/bad-row-original"
  if bash "$script" health --device /dev/zero --refresh --wake-ok --state-dir "$bad_row_state" > "$TMP/out" 2>&1; then
    fail "malformed snapshot $scenario row was accepted"
  fi
  grep -Fq 'Malformed SMART snapshot rows' "$TMP/out" || fail "missing malformed $scenario row diagnostic"
  cmp -s "$TMP/bad-row-original" "$bad_row_state/health/snapshots.tsv" || fail "malformed $scenario history was modified"
done
[[ $(wc -l < "$TMP/calls") -eq "$probes_before" ]] || fail 'malformed snapshot rows triggered SMART probe'
echo 'PASS: offline cached health, explicit wake guard, NVMe/ATA and SCSI/USB serial/WWN identity including placeholders, history, filters, unsafe storage and snapshot header/row rejection'
