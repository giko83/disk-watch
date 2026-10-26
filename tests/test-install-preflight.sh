#!/usr/bin/env bash
# Offline, unprivileged installer preflight regression test.
# No systemd operations, installed files, or real host configuration are touched.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/source" "$TMP/mock-bin"
cp "$ROOT/install.sh" "$ROOT/disk-watch.sh" "$ROOT/disk-watch-smart.sh" \
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

echo 'PASS: read-only installer preflight, missing file, invalid syntax and option validation'
