#!/usr/bin/env bash
# Disk Watch read-only cached disk reports. SMART collection is explicit opt-in.
set -euo pipefail
export LC_ALL=C
help() {
cat <<'HELP'
Usage: disk-watch.sh status|disks|health|history|report [options]
  status                         Cached journal and SMART summary
  disks                          Last saved health reading per disk
  health                         Same as disks; accepts --refresh
  history --device SERIAL|PATH   Saved SMART readings for one disk
  report [--since YYYY-MM-DD]    Saved readings since date
Options:
  --state-dir DIR    Override state storage
  --format text|tsv  Text or stable TSV output (default: text)
  --device ID        Explicit /dev path for refresh, or cached path/serial filter
  --refresh          Save a fresh SMART snapshot (health only)
  --wake-ok          Required with --refresh: SMART may spin up sleeping disks
Reading existing reports never calls smartctl, journalctl or any disk device.
HELP
}
(($#)) || { help >&2; exit 2; }
action=$1; shift
case $action in status|disks|health|history|report) ;; *) help >&2; exit 2;; esac
state=${DISK_WATCH_STATE_DIR:-/var/lib/disk-watch}
format=text device='' since='' refresh=0 wake=0
while (($#)); do
 case $1 in
  --help|-h) help; exit 0 ;;
  --state-dir|--format|--device|--since)
    key=$1
    (($# >= 2)) && [[ -n $2 ]] || { echo "Missing value: $key" >&2; exit 2; }
    case $key in
      --state-dir) state=$2;; --format) format=$2;; --device) device=$2;; --since) since=$2;;
    esac
    shift 2;;
  --refresh) refresh=1; shift;;
  --wake-ok) wake=1; shift;;
  *) echo "Unknown option: $1" >&2; exit 2;;
 esac
done
[[ $format == text || $format == tsv ]] || { echo 'Use --format text|tsv' >&2; exit 2; }
[[ -z $since || ( $action == report && $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ) ]] || { echo 'Use report --since YYYY-MM-DD' >&2; exit 2; }
[[ -z $device || $action == history || $action == health ]] || { echo 'Only health/history accept --device' >&2; exit 2; }
[[ $action != history || -n $device ]] || { echo 'history requires --device' >&2; exit 2; }
if ((refresh || wake)); then
  [[ $action == health && $refresh == 1 && $wake == 1 && -n $device ]] || {
    echo 'Live read requires health --device /dev/DEVICE --refresh --wake-ok' >&2; exit 2;
  }
fi
db="$state/health/snapshots.tsv"
header=$'timestamp_utc\tdevice\tid\tmodel\thealth\ttemperature_c\tpower_on_hours\treallocated\tpending\tmedia_errors\tgb_written\twear_percent\tlast_test'
clean() {
 local v=$1
 v=${v//$'\t'/ }
 v=${v//$'\n'/ }
 v=${v//$'\r'/ }
 printf '%s' "${v:0:180}"
}
if ((refresh)); then
  [[ $device == /dev/* && $device != *$'\n'* && $device != *$'\t'* ]] || {
    echo 'Explicit /dev/... path required' >&2; exit 2;
  }
  command -v smartctl >/dev/null || { echo 'smartctl required only for live refresh' >&2; exit 1; }
  echo "SMART read from $device may wake disk" >&2
  raw=$(smartctl -a -- "$device" 2>&1) || :
  grep -Eq '^(Model Number|Device Model|SMART overall-health self-assessment test result|SMART Health Status|SMART/Health Information)' <<<"$raw" || { echo 'No readable SMART report; snapshot not saved' >&2; exit 1; }
  model=$(awk -F: '/^(Device Model|Model Number):/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$raw")
  serial=$(awk -F: '/^Serial Number:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' <<<"$raw")
  id=$device
  [[ -z $serial ]] || id=$serial
  health=unavailable
  if grep -Eq 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|SMART Health Status:[[:space:]]*OK' <<<"$raw"; then health=passed
  elif grep -Eiq 'SMART overall-health self-assessment test result:[[:space:]]*FAILED|SMART Health Status:[[:space:]]*(FAILED|BAD)' <<<"$raw"; then health=failed
  fi
  temp=$(awk -F: '/^Temperature:/ {sub(/^[[:space:]]+/, "", $2); split($2,a," "); if(a[1] ~ /^[0-9]+$/) print a[1]; exit}' <<<"$raw")
  [[ -n $temp ]] || temp=$(awk '$2=="Temperature_Celsius" || $2=="Airflow_Temperature_Cel" {if($10 ~ /^[0-9]+$/) {print $10; exit}}' <<<"$raw")
  hours=$(awk -F: '/^Power On Hours:/ {sub(/^[[:space:]]+/, "", $2); gsub(/,/, "", $2); split($2,a," "); if(a[1] ~ /^[0-9]+$/) print a[1]; exit}' <<<"$raw")
  [[ -n $hours ]] || hours=$(awk '$2=="Power_On_Hours" && $10 ~ /^[0-9]+$/ {print $10; exit}' <<<"$raw")
  realloc=$(awk '$2=="Reallocated_Sector_Ct" && $10 ~ /^[0-9]+$/ {print $10; exit}' <<<"$raw")
  pending=$(awk '$2=="Current_Pending_Sector" && $10 ~ /^[0-9]+$/ {print $10; exit}' <<<"$raw")
  media=$(awk -F: '/^Media and Data Integrity Errors:/ {gsub(/[,[:space:]]/, "", $2); if($2 ~ /^[0-9]+$/) print $2; exit}' <<<"$raw")
  wear=$(awk -F: '/^Percentage Used:/ {gsub(/[ %]/, "", $2); if($2 ~ /^[0-9]+$/) print $2; exit}' <<<"$raw")
  gb=$(awk -F: '/^Data Units Written:/ {sub(/^[[:space:]]+/, "", $2); gsub(/,/, "", $2); split($2,a," "); if(a[1] ~ /^[0-9]+$/) printf "%.2f", a[1]*512000/1000000000; exit}' <<<"$raw")
  last_test=unavailable
  if grep -Eq 'Self-test status:.*in progress|Self-test execution status:.*in progress' <<<"$raw"; then last_test=in_progress
  elif grep -Eq '^#[[:space:]]*1[[:space:]]' <<<"$raw"; then
    last_test=$(awk '/^#[[:space:]]*1[[:space:]]/ {if($0 ~ /Completed without error/) print "completed_ok"; else if ($0 ~ /failure|Failed|Completed:/) print "failed_or_interrupted"; else print "unavailable"; exit}' <<<"$raw")
  fi
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fields=("$stamp" "$device" "$id" "${model:-unavailable}" "$health" "${temp:-unavailable}" "${hours:-unavailable}" "${realloc:-unavailable}" "${pending:-unavailable}" "${media:-unavailable}" "${gb:-unavailable}" "${wear:-unavailable}" "$last_test")
  for i in "${!fields[@]}"; do fields[$i]=$(clean "${fields[$i]}"); done
  umask 077
  mkdir -p -- "$state/health"
  [[ ! -L $db && ( ! -e $db || -f $db ) ]] || { echo 'Unsafe snapshot target' >&2; exit 1; }
  exec 9>"$state/health/.snapshots.lock"
  flock -x 9
  [[ -s $db ]] || printf '%s\n' "$header" > "$db"
  (IFS=$'\t'; printf '%s\n' "${fields[*]}") >> "$db"
  chmod 600 "$db"
  flock -u 9
  echo "Saved SMART snapshot for $id; reported health: $health (not a guarantee of reliability)" >&2
fi
# Everything after the optional explicit refresh is read-only and disk-safe.
# For status, TSV is key/value data rather than the snapshot row schema.
if [[ $action == status ]]; then
  if [[ $format == tsv ]]; then
    printf 'metric\tvalue\n'
    if [[ -s "$state/kernel.cursor" ]]; then printf 'journal_cursor\tavailable\n'
    else printf 'journal_cursor\tunavailable\n'; fi
  else
    echo 'Disk Watch cached status (no device access)'
    if [[ -s "$state/kernel.cursor" ]]; then echo 'Journal cursor: available'
    else echo 'Journal cursor: unavailable'; fi
  fi
  if [[ -s "$db" ]]; then
    stats=$(awk -F '\t' 'NR>1 && NF>=13 {n++; a[$3]=1; last=$1} END {for(k in a) d++; printf "%d\t%d\t%s", n,d,(last==""?"unavailable":last)}' "$db")
  else stats=$'0\t0\tunavailable'; fi
  IFS=$'\t' read -r n d last <<<"$stats"
  if [[ $format == tsv ]]; then
    printf 'snapshots\t%s\ndisks\t%s\nlast_snapshot\t%s\nlast_alert\tunavailable\n' "$n" "$d" "$last"
  else
    printf 'Snapshots: %s\nDisks with snapshots: %s\nLast snapshot: %s\n' "$n" "$d" "$last"
    echo 'Last alert: unavailable (event history not yet persisted)'
    [[ $n != 0 ]] || echo 'SMART history: unavailable (no saved snapshots)'
  fi
  exit 0
fi
if [[ $format == tsv ]]; then printf '%s\n' "$header"; fi
if [[ ! -s $db ]]; then
  [[ $format != text ]] || echo 'SMART history: unavailable (no saved snapshots).'
  exit 0
fi
# Format as compact records rather than a very wide TSV row in terminals.
format_rows() {
  if [[ $format == tsv ]]; then cat
  else awk -F '\t' 'NF>=13 {
    printf "Disk: %s (%s)\nLast seen: %s | SMART: %s | Last test: %s\n", $3,$4,$1,$5,$13;
    printf "Temp: %s C | Hours: %s | Reallocated: %s | Pending: %s\n", $6,$7,$8,$9;
    printf "Media errors: %s | Written: %s GB | Wear: %s %% | Path: %s\n\n", $10,$11,$12,$2;
  }'
  fi
}
# No smartctl/journalctl calls below this line. Column 3 uses a firmware
# serial if available; otherwise the explicit path. Never infer health from
# fields marked unavailable.
case $action in
 disks|health)
   awk -F '\t' -v wanted="$device" 'NR>1 && NF>=13 && (wanted=="" || $2==wanted || $3==wanted) {latest[$3]=$0} END {for(k in latest) print latest[k]}' "$db" | sort -t 
   ;;
 history)
   awk -F '\t' -v x="$device" 'NR>1 && NF>=13 && ($2==x || $3==x) {print}' "$db" | format_rows
   ;;
 report)
   awk -F '\t' -v date="$since" 'NR>1 && NF>=13 && (date=="" || substr($1,1,10)>=date) {print}' "$db" | format_rows
   ;;
esac
\t' -k3,3 | format_rows
   ;;
 history)
   awk -F '\t' -v x="$device" 'NR>1 && NF>=13 && ($2==x || $3==x) {print}' "$db" | format_rows
   ;;
 report)
   awk -F '\t' -v date="$since" 'NR>1 && NF>=13 && (date=="" || substr($1,1,10)>=date) {print}' "$db" | format_rows
   ;;
esac
