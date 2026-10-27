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

echo 'PASS: read-only installer preflight, updater validation, unit and SMART adapter checks, invalid syntax and options'
