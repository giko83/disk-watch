#!/usr/bin/env bash
# Offline, unprivileged installer preflight regression test.
# No systemd operations, installed files, or real host configuration are touched.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/source" "$TMP/mock-bin"
cp "$ROOT/install.sh" "$ROOT/update.sh" "$ROOT/disk-watch.sh" "$ROOT/disk-watch-smart.sh" \
   "$ROOT/disk-watch.service" "$ROOT/disk-watch.timer" "$TMP/source/"
mkdir -p "$TMP/source/scripts"
cp "$ROOT/scripts/backup-installed.sh" "$ROOT/scripts/check-config.sh" "$TMP/source/scripts/"

# If the preflight ever calls systemctl rather than just checking availability,
# the mock leaves a detectable marker and fails.
cat > "$TMP/mock-bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'called\n' >> "$MOCK_SYSTEMCTL_LOG"
exit 70
MOCK
chmod +x "$TMP/mock-bin/systemctl"
export MOCK_SYSTEMCTL_LOG="$TMP/systemctl.called"
export PATH="$TMP/mock-bin:$PATH"

bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err" ||
  fail 'valid checkout failed preflight'
grep -Fq 'Preflight OK' "$TMP/out" || fail 'missing success diagnostic'
[[ ! -e "$TMP/systemctl.called" ]] || fail 'preflight invoked systemctl'
[[ ! -e "$TMP/source/kernel.cursor" ]] || fail 'preflight created a cursor'

mv "$TMP/source/disk-watch.timer" "$TMP/missing-timer"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing unit file passed preflight'
fi
grep -Fq 'missing or empty disk-watch.timer' "$TMP/err" ||
  fail 'missing unit diagnostic absent'
mv "$TMP/missing-timer" "$TMP/source/disk-watch.timer"

# A missing updater must not pass a deployment preflight.
mv "$TMP/source/update.sh" "$TMP/missing-updater"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing update.sh passed preflight'
fi
grep -Fq 'missing or empty update.sh' "$TMP/err" ||
  fail 'missing updater diagnostic absent'
mv "$TMP/missing-updater" "$TMP/source/update.sh"

# A missing backup helper must be caught before any installed file changes.
mv "$TMP/source/scripts/backup-installed.sh" "$TMP/missing-backup"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing backup helper passed preflight'
fi
grep -Fq 'missing or empty scripts/backup-installed.sh' "$TMP/err" ||
  fail 'missing backup helper diagnostic absent'
mv "$TMP/missing-backup" "$TMP/source/scripts/backup-installed.sh"

# Reject a syntactically broken backup helper.
printf '%s\n' 'if then' >> "$TMP/source/scripts/backup-installed.sh"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'broken backup helper syntax passed preflight'
fi
grep -Fq 'invalid Bash syntax' "$TMP/err" ||
  fail 'invalid backup helper diagnostic absent'
cp "$ROOT/scripts/backup-installed.sh" "$TMP/source/scripts/backup-installed.sh"

# A missing or broken config metadata checker must block deployment preflight.
mv "$TMP/source/scripts/check-config.sh" "$TMP/missing-config-check"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing config checker passed preflight'
fi
grep -Fq 'missing or empty scripts/check-config.sh' "$TMP/err" ||
  fail 'missing config checker diagnostic absent'
mv "$TMP/missing-config-check" "$TMP/source/scripts/check-config.sh"
printf '%s\n' 'if then' >> "$TMP/source/scripts/check-config.sh"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'broken config checker syntax passed preflight'
fi
grep -Fq 'invalid Bash syntax' "$TMP/err" ||
  fail 'invalid config checker diagnostic absent'
cp "$ROOT/scripts/check-config.sh" "$TMP/source/scripts/check-config.sh"

# Reject broken updater syntax before replacing installed files.
printf '%s\n' 'if then' >> "$TMP/source/update.sh"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'broken updater syntax passed preflight'
fi
grep -Fq 'invalid Bash syntax' "$TMP/err" ||
  fail 'invalid updater syntax diagnostic absent'
cp "$ROOT/update.sh" "$TMP/source/update.sh"

# A syntactically valid unit pointing at the wrong command must fail before
# deployment; neither unit check should invoke systemctl.
sed -i 's@ExecStart=/usr/local/sbin/disk-watch.sh scan@ExecStart=/bin/false@' "$TMP/source/disk-watch.service"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'mismatched service ExecStart passed preflight'
fi
grep -Fq 'ExecStart does not match' "$TMP/err" ||
  fail 'missing service entry point diagnostic'
sed -i 's@ExecStart=/bin/false@ExecStart=/usr/local/sbin/disk-watch.sh scan@' "$TMP/source/disk-watch.service"

sed -i 's/Unit=disk-watch.service/Unit=other.service/' "$TMP/source/disk-watch.timer"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'mismatched timer target passed preflight'
fi
grep -Fq 'does not target disk-watch.service' "$TMP/err" ||
  fail 'missing timer target diagnostic'
sed -i 's/Unit=other.service/Unit=disk-watch.service/' "$TMP/source/disk-watch.timer"
[[ ! -e "$TMP/systemctl.called" ]] || fail 'unit validation invoked systemctl'

# A valid entry followed by another active entry must not pass preflight.
# A simple grep -Fxq would accept the first line despite a later override.
printf '\nExecStart=/bin/false\n' >> "$TMP/source/disk-watch.service"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'duplicate service ExecStart passed preflight'
fi
grep -Fq 'duplicate or missing ExecStart directives' "$TMP/err" ||
  fail 'duplicate service directive diagnostic absent'
cp "$ROOT/disk-watch.service" "$TMP/source/disk-watch.service"

printf '\nUnit=other.service\n' >> "$TMP/source/disk-watch.timer"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'duplicate timer Unit passed preflight'
fi
grep -Fq 'duplicate or missing Unit directives' "$TMP/err" ||
  fail 'duplicate timer directive diagnostic absent'
cp "$ROOT/disk-watch.timer" "$TMP/source/disk-watch.timer"
[[ ! -e "$TMP/systemctl.called" ]] || fail 'duplicate directive validation invoked systemctl'

# A syntactically valid SMART adapter targeting another command must fail.
# This prevents a successful install with silently broken smartd forwarding.
sed -i 's@exec /usr/local/sbin/disk-watch.sh smart@exec /bin/true@' "$TMP/source/disk-watch-smart.sh"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'mismatched SMART adapter passed preflight'
fi
grep -Fq 'does not forward to the installed SMART handler' "$TMP/err" ||
  fail 'missing SMART adapter diagnostic'
cp "$ROOT/disk-watch-smart.sh" "$TMP/source/disk-watch-smart.sh"
[[ ! -e "$TMP/systemctl.called" ]] || fail 'SMART adapter validation invoked systemctl'

printf '\nif then\n' >> "$TMP/source/disk-watch.sh"
if bash "$TMP/source/install.sh" --preflight > "$TMP/out" 2> "$TMP/err"; then
  fail 'broken Bash syntax passed preflight'
fi
grep -Fq 'invalid Bash syntax' "$TMP/err" ||
  fail 'invalid Bash syntax diagnostic absent'

if bash "$TMP/source/install.sh" --unexpected > "$TMP/out" 2> "$TMP/err"; then
  fail 'unknown installer option accepted'
fi
grep -Fq 'Usage:' "$TMP/err" || fail 'invalid option diagnostic absent'
[[ ! -e "$TMP/systemctl.called" ]] || fail 'preflight or argument error invoked systemctl'

# Root-owned configuration validation is isolated from the host and tested
# with a mocked GNU stat: no root access or real /etc file is needed.
printf '%s\n' 'HOST_LABEL=test' > "$TMP/host-config"
chmod 600 "$TMP/host-config"
cat > "$TMP/mock-bin/stat" <<'MOCK'
#!/usr/bin/env bash
case "${2:-}" in
  %u) printf '%s\n' "${MOCK_STAT_UID:-0}" ;;
  %a) printf '%s\n' "${MOCK_STAT_MODE:-600}" ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$TMP/mock-bin/stat"
check="$TMP/source/scripts/check-config.sh"
MOCK_STAT_UID=0 MOCK_STAT_MODE=600 bash "$check" "$TMP/host-config" ||
  fail 'secure root-owned mode 600 rejected'
MOCK_STAT_UID=0 MOCK_STAT_MODE=400 bash "$check" "$TMP/host-config" ||
  fail 'secure root-owned read-only mode 400 rejected'
if MOCK_STAT_UID=1000 MOCK_STAT_MODE=600 bash "$check" "$TMP/host-config" > "$TMP/out" 2> "$TMP/err"; then
  fail 'non-root-owned config accepted'
fi
grep -Fq 'owned by root' "$TMP/err" || fail 'missing ownership diagnostic'
for mode in 640 644 777; do
  if MOCK_STAT_UID=0 MOCK_STAT_MODE="$mode" bash "$check" "$TMP/host-config" > "$TMP/out" 2> "$TMP/err"; then
    fail "insecure config mode $mode accepted"
  fi
  grep -Fq 'must not be accessible to group or others' "$TMP/err" ||
    fail "missing permissions diagnostic for mode $mode"
done
if MOCK_STAT_UID=0 MOCK_STAT_MODE=garbled bash "$check" "$TMP/host-config" > "$TMP/out" 2> "$TMP/err"; then
  fail 'malformed stat mode accepted'
fi
ln -s "$TMP/host-config" "$TMP/config-link"
if bash "$check" "$TMP/config-link" > "$TMP/out" 2> "$TMP/err"; then
  fail 'symlink config accepted'
fi
if bash "$check" "$TMP/no-such-config" > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing config accepted'
fi
if bash "$check" > "$TMP/out" 2> "$TMP/err"; then
  fail 'config checker without path accepted'
fi
[[ ! -e "$TMP/systemctl.called" ]] || fail 'config checker invoked systemctl'

echo 'PASS: installer preflight and isolated root-config metadata guard, including unsafe modes and symlinks'
