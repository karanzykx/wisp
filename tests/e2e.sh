#!/usr/bin/env bash
# End-to-end tests for the Wisp engine.
#
# Runs the real engine (engine/wisp.sh) with HOME pointed at a throwaway folder
# full of fake caches, logs, browser profiles and projects, then checks exactly
# what was removed and — more importantly — what survived. Nothing outside the
# temporary folder is read or changed.
#
#   tests/e2e.sh
# shellcheck disable=SC2016  # bash -c snippets are single-quoted on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/engine/wisp.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/wisp-e2e.XXXXXX")"
T="$(cd "$T" && pwd -P)"                      # resolve /var → /private/var so lsof paths match
trap 'rm -rf "$T"; [[ -n "${HOLD_PID:-}" ]] && kill "$HOLD_PID" 2>/dev/null; true' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$*"; }
expect() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
group() { printf '\n%s\n' "$*"; }

wisp() { env HOME="$T" TMPDIR="$T/tmp" WISP_SKIP_TOOLS=1 /bin/bash "$ENGINE" "$@" 2>&1; }
blob() { mkdir -p "$(dirname "$1")"; dd if=/dev/zero of="$1" bs=1024 count="${2:-1024}" 2>/dev/null; }
gone()   { [[ ! -e "$T/$1" ]]; }
exists() { [[ -e "$T/$1" ]]; }
count_files() { find "$T" -type f -not -path "$T/Library/Logs/Wisp/*" -not -path "$T/tmp/*" | wc -l | tr -d ' '; }
cats() { grep -E '^@@CAT' | cut -f2 | sort | tr '\n' ' '; }

fixture() {
  rm -rf "${T:?}"/* "$T"/.config "$T"/.ssh
  mkdir -p "$T/tmp"
  # caches
  blob "$T/Library/Caches/appA/blob" 2048
  blob "$T/Library/Caches/appKeep/blob" 2048
  blob "$T/Library/Caches/com.apple.bird/blob" 2048
  blob "$T/Library/Caches/com.vivaldi.Vivaldi/Default/Cache/blob" 2048
  # browser profile (logins, passkeys) and an Electron app
  # (Vivaldi and "WispFakeEditor" are used because real apps on the machine running the tests would be skipped as "in use")
  local brave="$T/Library/Application Support/Vivaldi/Default"
  mkdir -p "$brave"
  echo secret >"$brave/Cookies"
  echo password >"$brave/Login Data"
  blob "$brave/Local Storage/leveldb/000003.log" 64
  blob "$brave/Cache/blob" 2048
  local code="$T/Library/Application Support/WispFakeEditor"
  blob "$code/Cache/blob" 2048; blob "$code/CachedData/blob" 2048; blob "$code/Code Cache/blob" 2048
  mkdir -p "$code/User"; echo '{"editor.fontSize":14}' >"$code/User/settings.json"
  # logs
  blob "$T/Library/Logs/old.log" 1024; touch -t 202001010000 "$T/Library/Logs/old.log"
  blob "$T/Library/Logs/new.log" 1024
  # personal files that must never be touched
  mkdir -p "$T/Documents" "$T/Desktop" "$T/.ssh" "$T/Library/Keychains"
  echo precious >"$T/Documents/thesis.txt"; echo note >"$T/Desktop/note.txt"
  echo key >"$T/.ssh/id_ed25519"; echo kc >"$T/Library/Keychains/login.keychain-db"
  # projects
  local pr
  for pr in old fresh; do
    blob "$T/Projects/$pr/node_modules/x/blob" 2048
    echo '{}' >"$T/Projects/$pr/package.json"; echo '{}' >"$T/Projects/$pr/package-lock.json"
    echo 'code' >"$T/Projects/$pr/index.js"
  done
  touch -t 202001010000 "$T/Projects/old" "$T/Projects/old/package.json" "$T/Projects/old/package-lock.json" \
        "$T/Projects/old/index.js" "$T/Projects/old/node_modules/x/blob"
  blob "$T/Projects/nolock/node_modules/x/blob" 2048; echo '{}' >"$T/Projects/nolock/package.json"
  touch -t 202001010000 "$T/Projects/nolock" "$T/Projects/nolock/package.json" "$T/Projects/nolock/node_modules/x/blob"
  # never-touch list
  mkdir -p "$T/.config/wisp"; printf '# keep list\nappKeep\n' >"$T/.config/wisp/keep.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
group "1. Dry run deletes nothing and lists every category"
fixture
before="$(count_files)"
out="$(wisp --dry-run --yes --app --no-report)"
expect "dry run removed no files"                      test "$(count_files)" = "$before"
found="$(printf '%s\n' "$out" | cats)"
for c in appcaches browsers electron logs projdeps; do
  expect "category '$c' is listed"                     test "${found#*"$c"}" != "$found"
done
expect "a result line is printed"                      grep -q '^@@RESULT' <<<"$out"
expect "never-touch entry is not offered"              bash -c '! grep -q "appKeep" <<<"$1"' _ "$out"
expect "protected Apple cache is not offered"          bash -c '! grep -q "com.apple.bird" <<<"$1"' _ "$out"
expect "recent project is not offered"                 bash -c '! grep -q "Projects/fresh" <<<"$1"' _ "$out"
expect "project without a lockfile is not offered"     bash -c '! grep -q "Projects/nolock" <<<"$1"' _ "$out"

# ─────────────────────────────────────────────────────────────────────────────
group "2. Cleaning caches never touches logins, settings or personal files"
fixture
wisp --yes --app --no-report --only browsers,appcaches,electron,logs >/dev/null
expect "app cache removed"                             gone "Library/Caches/appA"
expect "browser web cache removed"                     gone "Library/Caches/com.vivaldi.Vivaldi"
expect "editor Cache removed"                          gone "Library/Application Support/WispFakeEditor/Cache"
expect "editor CachedData removed"                     gone "Library/Application Support/WispFakeEditor/CachedData"
expect "old log removed"                               gone "Library/Logs/old.log"
expect "recent log kept"                               exists "Library/Logs/new.log"
expect "never-touch cache kept"                        exists "Library/Caches/appKeep/blob"
expect "Apple system cache kept"                       exists "Library/Caches/com.apple.bird/blob"
expect "browser Cookies kept"                          exists "Library/Application Support/Vivaldi/Default/Cookies"
expect "browser Login Data kept"                       exists "Library/Application Support/Vivaldi/Default/Login Data"
expect "browser Local Storage kept"                    exists "Library/Application Support/Vivaldi/Default/Local Storage/leveldb/000003.log"
expect "browser profile cache folder kept"             exists "Library/Application Support/Vivaldi/Default/Cache/blob"
expect "editor settings kept"                          exists "Library/Application Support/WispFakeEditor/User/settings.json"
expect "Documents kept"                                exists "Documents/thesis.txt"
expect "Desktop kept"                                  exists "Desktop/note.txt"
expect "SSH key kept"                                  exists ".ssh/id_ed25519"
expect "Keychain kept"                                 exists "Library/Keychains/login.keychain-db"
expect "unselected category (projdeps) untouched"      exists "Projects/old/node_modules/x/blob"

# ─────────────────────────────────────────────────────────────────────────────
group "3. Old project dependencies: only rebuildable folders, only when idle"
wisp --yes --app --no-report --only projdeps >/dev/null
expect "idle project's node_modules removed"           gone "Projects/old/node_modules"
expect "its package.json kept"                         exists "Projects/old/package.json"
expect "its lockfile kept"                             exists "Projects/old/package-lock.json"
expect "its source kept"                               exists "Projects/old/index.js"
expect "recently used project untouched"               exists "Projects/fresh/node_modules/x/blob"
expect "project without lockfile untouched"            exists "Projects/nolock/node_modules/x/blob"

# ─────────────────────────────────────────────────────────────────────────────
group "4. Running again is safe"
out="$(wisp --yes --app --no-report)"; rc=$?
expect "second run exits 0"                            test "$rc" = 0
expect "second run reports a result"                   grep -q '^@@RESULT' <<<"$out"
expect "personal files still intact"                   exists "Documents/thesis.txt"

# ─────────────────────────────────────────────────────────────────────────────
group "5. Symlinks are never followed"
fixture
ln -s "$T/Documents" "$T/Library/Caches/sneaky"
wisp --yes --app --no-report >/dev/null
expect "symlink target survived"                       exists "Documents/thesis.txt"

# ─────────────────────────────────────────────────────────────────────────────
group "6. Files in use are skipped"
fixture
blob "$T/Library/Caches/busyapp/blob" 2048
tail -f "$T/Library/Caches/busyapp/blob" >/dev/null 2>&1 &     # keeps the file open
HOLD_PID=$!
sleep 1
wisp --yes --app --no-report --only appcaches >/dev/null
expect "cache with an open file kept"                  exists "Library/Caches/busyapp/blob"
expect "idle cache next to it removed"                 gone "Library/Caches/appA"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""

# ─────────────────────────────────────────────────────────────────────────────
group "7. Never-touch list accepts folder names"
fixture
printf 'WispFakeEditor\n' >"$T/.config/wisp/keep.txt"
wisp --yes --app --no-report --only electron >/dev/null
expect "app named in the list is skipped"              exists "Library/Application Support/WispFakeEditor/Cache/blob"

# ─────────────────────────────────────────────────────────────────────────────
group "8. Only one clean at a time"
fixture
mkdir -p "$T/tmp/wisp.lock"; echo $$ >"$T/tmp/wisp.lock/pid"
out="$(wisp --yes --app --no-report)"; rc=$?
expect "second instance refuses to run"                test "$rc" = 1
expect "second instance reports 'busy'"                grep -q '^@@ERROR.busy' <<<"$out"
expect "nothing was deleted while locked"              exists "Library/Caches/appA/blob"
rm -rf "$T/tmp/wisp.lock"

# ─────────────────────────────────────────────────────────────────────────────
group "9. Bad input is rejected, not guessed"
expect "unknown option exits 2"                        bash -c 'env HOME="$1" /bin/bash "$2" --bogus >/dev/null 2>&1; [ $? = 2 ]' _ "$T" "$ENGINE"
expect "non-numeric --days exits 2"                    bash -c 'env HOME="$1" /bin/bash "$2" --days abc >/dev/null 2>&1; [ $? = 2 ]' _ "$T" "$ENGINE"
expect "bad --only value exits 2"                      bash -c 'env HOME="$1" /bin/bash "$2" --only "a;rm" >/dev/null 2>&1; [ $? = 2 ]' _ "$T" "$ENGINE"
expect "refuses to run as a different HOME of /"       bash -c 'env HOME=/ /bin/bash "$1" --dry-run >/dev/null 2>&1; [ $? != 0 ]' _ "$ENGINE"
expect "--version prints x.y.z"                        bash -c '/bin/bash "$1" --version | grep -Eq "^wisp [0-9]+\.[0-9]+\.[0-9]+$"' _ "$ENGINE"

# ─────────────────────────────────────────────────────────────────────────────
group "10. Dart pub cache and Conda package cache: only the download caches go"
fixture
blob "$T/.pub-cache/hosted/pub.dev/http-1.0.0/lib/http.dart" 64
blob "$T/.pub-cache/global_packages/tool/pubspec.lock" 8
blob "$T/.pub-cache/bin/tool" 8
blob "$T/.pub-cache/git/repo/blob" 8
blob "$T/.conda/pkgs/numpy-1.0/blob" 64
blob "$T/.conda/envs/work/bin/python" 64
echo ".conda/envs" >"$T/.conda/environments.txt"
blob "$T/miniconda3/pkgs/numpy-1.0/blob" 64
blob "$T/miniconda3/bin/conda" 8
blob "$T/miniconda3/envs/work/bin/python" 64
blob "$T/miniforge3/pkgs/numpy-1.0/blob" 64
blob "$T/miniforge3/conda-meta/history" 8
blob "$T/Library/Caches/appA/blob" 64
wisp --yes --app --no-report --only appcaches >/dev/null
expect "unselected devcaches: pub cache untouched"     exists ".pub-cache/hosted/pub.dev/http-1.0.0/lib/http.dart"
expect "unselected devcaches: conda pkgs untouched"    exists "miniconda3/pkgs/numpy-1.0/blob"
wisp --yes --app --no-report --only devcaches >/dev/null
expect "pub hosted cache removed"                      gone ".pub-cache/hosted"
expect "pub global tools kept"                         exists ".pub-cache/global_packages/tool/pubspec.lock"
expect "pub bin folder kept"                           exists ".pub-cache/bin/tool"
expect "pub git cache kept"                            exists ".pub-cache/git/repo/blob"
expect "~/.conda/pkgs removed"                         gone ".conda/pkgs"
expect "~/.conda envs kept"                            exists ".conda/envs/work/bin/python"
expect "~/.conda/environments.txt kept"                exists ".conda/environments.txt"
expect "miniconda3 pkgs removed"                       gone "miniconda3/pkgs"
expect "miniconda3 base environment kept"              exists "miniconda3/bin/conda"
expect "miniconda3 environment kept"                   exists "miniconda3/envs/work/bin/python"
expect "miniforge3 pkgs removed"                       gone "miniforge3/pkgs"
expect "miniforge3 conda-meta kept"                    exists "miniforge3/conda-meta/history"
expect "other category (appcaches) untouched"          exists "Library/Caches/appA/blob"

# ─────────────────────────────────────────────────────────────────────────────
group "11. Built-in self-test passes"
fixture
expect "engine --self-test exits 0"                    bash -c 'env HOME="$1" TMPDIR="$1/tmp" /bin/bash "$2" --self-test >/dev/null 2>&1' _ "$T" "$ENGINE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
