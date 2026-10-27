#!/usr/bin/env bash
# Offline updater control-flow tests. No root, real git pull, installation or network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/mock-bin" "$TMP/repo/.git"
RUNNER="$TMP/isolated-update.sh"
# The real updater enforces root. Remove that one line only from a throwaway
# test copy so CI can exercise the remaining control flow unprivileged.
guard="[[ \${EUID} -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }"
grep -Fxq "$guard" "$ROOT/update.sh" || fail 'root guard changed; review test isolation'
awk -v guard="$guard" '$0 == guard {print "# Root check disabled in offline test copy only"; next} {print}' \
  "$ROOT/update.sh" > "$RUNNER"
[[ $(grep -Fc 'Root check disabled in offline test copy only' "$RUNNER") == 1 ]] ||
  fail 'failed to isolate updater root guard'

cat > "$TMP/mock-bin/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'status --porcelain')
    if [[ ${MOCK_DIRTY:-0} == 1 ]]; then echo ' M update.sh'; fi
    ;;
  'rev-parse HEAD') echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
  'pull --ff-only')
    if [[ ${MOCK_PULL_FAIL:-0} == 1 ]]; then echo 'mock pull failed' >&2; exit 41; fi
    ;;
  'rev-parse --short HEAD') echo 'bbbbbbb' ;;
  *) echo "unexpected git invocation: $*" >&2; exit 66 ;;
esac
MOCK
cat > "$TMP/repo/install.sh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  --preflight)
    echo 'install --preflight' >> "$MOCK_LOG"
    [[ ${MOCK_PREFLIGHT_FAIL:-0} != 1 ]] || { echo 'mock preflight failed' >&2; exit 42; }
    ;;
  '')
    echo 'install' >> "$MOCK_LOG"
    [[ ${MOCK_INSTALL_FAIL:-0} != 1 ]] || { echo 'mock install failed' >&2; exit 43; }
    ;;
  *) echo "unexpected installer args: $*" >&2; exit 67 ;;
esac
MOCK
chmod +x "$TMP/mock-bin/git"
export PATH="$TMP/mock-bin:$PATH" MOCK_LOG="$TMP/operations.log"
export DISK_WATCH_REPO="$TMP/repo"

: > "$MOCK_LOG"
if DISK_WATCH_REPO="$TMP/missing" bash "$RUNNER" > "$TMP/out" 2> "$TMP/err"; then
  fail 'missing Git checkout accepted'
fi
grep -Fq 'Not a Git checkout' "$TMP/err" || fail 'missing checkout diagnostic absent'
[[ ! -s "$MOCK_LOG" ]] || fail 'missing checkout invoked Git or installer'

: > "$MOCK_LOG"
if MOCK_DIRTY=1 bash "$RUNNER" > "$TMP/out" 2> "$TMP/err"; then
  fail 'dirty checkout accepted'
fi
grep -Fq 'Checkout has local modifications' "$TMP/err" || fail 'dirty checkout diagnostic absent'
! grep -Eq 'pull|install' "$MOCK_LOG" || fail 'dirty checkout triggered pull/install'

: > "$MOCK_LOG"
if MOCK_PULL_FAIL=1 bash "$RUNNER" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed pull accepted'
fi
grep -Fxq 'git pull --ff-only' "$MOCK_LOG" || fail 'updater did not require fast-forward pull'
! grep -Fq 'install' "$MOCK_LOG" || fail 'failed pull triggered installer'

: > "$MOCK_LOG"
if MOCK_PREFLIGHT_FAIL=1 bash "$RUNNER" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed preflight accepted'
fi
grep -Fq 'installed files were not replaced' "$TMP/err" || fail 'preflight failure diagnostic absent'
grep -Fxq 'install --preflight' "$MOCK_LOG" || fail 'preflight not invoked'
! grep -Fxq 'install' "$MOCK_LOG" || fail 'failed preflight invoked deployment'

: > "$MOCK_LOG"
if MOCK_INSTALL_FAIL=1 bash "$RUNNER" > "$TMP/out" 2> "$TMP/err"; then
  fail 'failed installation accepted'
fi
grep -Fq 'Install failed. Previous revision: aaaaaaaa' "$TMP/err" ||
  fail 'failed installation diagnostic missing old revision'
grep -Fxq 'install' "$MOCK_LOG" || fail 'installation was not attempted'

: > "$MOCK_LOG"
bash "$RUNNER" > "$TMP/out" 2> "$TMP/err" || fail 'clean update failed'
cat > "$TMP/expected" <<'EXPECTED'
git status --porcelain
git rev-parse HEAD
git pull --ff-only
install --preflight
install
git rev-parse --short HEAD
EXPECTED
diff -u "$TMP/expected" "$MOCK_LOG" || fail 'update operations ran out of order'
grep -Fq 'Disk Watch updated to bbbbbbb' "$TMP/out" || fail 'success diagnostic absent'

echo 'PASS: offline updater checkout, dirty-tree, fast-forward, preflight, deployment failure and success flow'
