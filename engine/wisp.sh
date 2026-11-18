#!/usr/bin/env bash
# =============================================================================
#  wisp: the safe, one-click deep clean for developer Macs
#
#  Design rules
#    1. Only regenerable data is ever deleted: caches, old logs, build output,
#       package-manager downloads. Never documents, preferences, backups,
#       databases, Docker volumes, virtualenvs, IDE local history or keychains.
#    2. Every deletion passes guard_path(): the target must sit strictly inside
#       a short allowlist of cache/log roots, or it is refused.
#    3. Anything a running process has open (lsof) or that belongs to a running
#       app is skipped, so nothing is pulled out from under a live program.
#    4. --dry-run is a real dry run: all deletions go through three primitives
#       (nuke / prune_old / run_cmd) and each of them is a no-op in dry-run.
#    5. Browser profiles (sign-ins, passkeys, saved passwords) are refused
#       outright; only the web cache under ~/Library/Caches may go.
#    6. node_modules / vendor / target are removed only when a manifest AND a
#       lockfile sit beside them and the project has been idle for 90+ days.
#    7. No sudo unless you pass --system.
#
#  Usage
#    wisp --dry-run     preview everything, delete nothing
#    wisp               interactive: scan, show sizes, ask
#    wisp --yes         no prompts; takes each prompt's default
#                                      (safe items yes, costly/risky items no)
#    wisp --dry-run --yes   preview exactly what --yes would do
#  Options
#    -n, --dry-run     preview only
#    -y, --yes         accept the default answer of every prompt
#        --days N      delete logs older than N days (default 7)
#        --system      also prune system logs / crash reports (uses sudo)
#        --maintenance also offer DNS flush and Spotlight re-index (uses sudo)
#        --no-report   skip the "worth a look" report at the end
#        --self-test   prove the safety guards work on this Mac, then exit
#        --only IDS    clean only these categories (comma-separated ids), e.g.
#                      browsers,appcaches,electron,logs,xcode,devsupport,simulators,
#                      pkgcaches,pnpm,depstores,devcaches,brew,brewauto,docker,projdeps,trash
#        --insights    read-only: list large files and big folders worth a look
#        --dep-days N  "old project" threshold for node_modules/vendor/target (default 90)
#        --app         machine-readable progress lines (used by Wisp.app)
#        --version     print version
#    -h, --help        show this help
#
#  Never-touch list
#    Put one path or folder name per line in ~/.config/wisp/keep.txt
#    and it will never be cleaned, e.g.
#        ~/Library/Caches/com.spotify.client
#        Cursor
#
#  Extra project folders to check for old dependencies (one per line, inside
#  your home folder): ~/.config/wisp/roots.txt
#
#  Works with the stock macOS bash 3.2 on every Mac (Apple Silicon and Intel).
# =============================================================================

set -uo pipefail

# ── Options ──────────────────────────────────────────────────────────────────
VERSION="0.1.0"
DRY_RUN=false; ASSUME_YES=false; SYSTEM=false; MAINT=false; LOG_DAYS=7
APP_MODE=false; NO_REPORT=false; SELF_TEST=false; ONLY=""; INSIGHTS=false; DEP_DAYS=90

while (( $# )); do
  case "$1" in
    -n|--dry-run)   DRY_RUN=true ;;
    -y|--yes)       ASSUME_YES=true ;;
    --system)       SYSTEM=true ;;
    --maintenance)  MAINT=true ;;
    --days)         shift; LOG_DAYS="${1:-}" ;;
    --no-report)    NO_REPORT=true ;;
    --self-test)    SELF_TEST=true ;;
    --app)          APP_MODE=true ;;
    --only)         shift; ONLY="${1:-}" ;;
    --insights)     INSIGHTS=true ;;
    --dep-days)     shift; DEP_DAYS="${1:-}" ;;
    --version)      echo "wisp $VERSION"; exit 0 ;;
    -h|--help)      awk '/^# =+$/{n++; next} n==1{sub(/^# ?/,""); print} n>=2{exit}' "$0"; exit 0 ;;
    *)              echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ── Preconditions ────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || { echo "This script is for macOS only." >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -ne 0 ]] || { echo "Do not run as root/sudo. Run as yourself; use --system for system logs." >&2; exit 1; }
[[ -n "${HOME:-}" && "$HOME" == /* && "$HOME" != "/" && -d "$HOME" ]] || { echo "HOME is not sane; aborting." >&2; exit 1; }
[[ "$LOG_DAYS" =~ ^[0-9]+$ && "$LOG_DAYS" -ge 1 ]] || { echo "--days needs a whole number >= 1" >&2; exit 2; }
[[ "$DEP_DAYS" =~ ^[0-9]+$ && "$DEP_DAYS" -ge 14 ]] || { echo "--dep-days needs a whole number >= 14" >&2; exit 2; }
[[ -z "$ONLY" || "$ONLY" =~ ^[a-z_,]+$ ]] || { echo "--only takes comma-separated category ids" >&2; exit 2; }
HOME="${HOME%/}"
cd "$HOME" || exit 1          # so no tool picks up a project-local config
# Apps launched from Finder get a bare PATH; make brew/docker/pnpm findable.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/Library/pnpm:$HOME/.bun/bin"
export PATH

# ── Output ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
  CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; YELLOW=""; GREEN=""; CYAN=""; DIM=""; BOLD=""; RESET=""
fi

LOG_DIR="$HOME/Library/Logs/Wisp"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/run_$(date +%Y%m%d_%H%M%S).log"
# keep only the 20 most recent run logs
# shellcheck disable=SC2012  # file names are our own timestamps
ls -t "$LOG_DIR"/run_*.log 2>/dev/null | tail -n +21 | while IFS= read -r old; do rm -f -- "$old"; done

# Machine-readable progress for the GUI wrapper (tab-separated, "@@" prefix).
emit() { if $APP_MODE; then local IFS=$'\t'; printf '@@%s\n' "$*"; fi; return 0; }

log()  { printf '%s\n' "$*"; printf '%s\n' "$*" | sed $'s/\033\\[[0-9;]*m//g' >>"$LOG_FILE" 2>/dev/null; }
info() { log "  $*"; }
note() { log "  ${DIM}$*${RESET}"; }
warn() { log "  ${YELLOW}!${RESET} $*"; }
ok()   { log "  ${GREEN}✓${RESET} $*"; }
err()  { log "  ${RED}✗${RESET} $*"; }
section() { log ""; log "${BOLD}${CYAN}── $* ${RESET}"; emit SECTION "$*"; }

have()   { [[ -z "${WISP_SKIP_TOOLS:-}" ]] && command -v "$1" >/dev/null 2>&1; }   # WISP_SKIP_TOOLS=1: tests ignore brew/docker/pnpm
pretty() { if [[ "$1" == "$HOME"* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi; }
human()  { awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.2f GB",k/1048576; else if(k>=1024) printf "%.1f MB",k/1024; else printf "%d KB",k }'; }
size_kb() { local kb; kb=$(du -sk -- "$1" 2>/dev/null | awk 'NR==1{print $1+0}'); echo "${kb:-0}"; }
free_kb() { df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4+0}'; }

# ── Safety core ──────────────────────────────────────────────────────────────
# A path may be deleted only if it is STRICTLY INSIDE one of these roots.
ALLOWED_ROOTS=(
  "$HOME/Library/Caches"
  "$HOME/Library/Logs"
  "$HOME/Library/Application Support"            # further restricted below
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"
  "$HOME/Library/Developer/Xcode/tvOS DeviceSupport"
  "$HOME/Library/Developer/CoreSimulator/Caches"
  "$HOME/.npm"
  "$HOME/.cache"
  "$HOME/.yarn/berry"
  "$HOME/.bun/install"
  "$HOME/.composer"
  "$HOME/.gradle"
  "$HOME/.ivy2"
  "$HOME/.cargo/registry"
  "$HOME/.pub-cache"
  "$HOME/.conda"
  "$HOME/miniconda3"
  "$HOME/anaconda3"
  "$HOME/miniforge3"
  "$HOME/mambaforge"
  "$HOME/micromamba"
)

# User's never-touch list.
KEEP=(); KEEP_FILE="$HOME/.config/wisp/keep.txt"
if [[ -f "$KEEP_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == "~"* ]] && line="$HOME${line#\~}"
    KEEP+=("${line%/}")
  done <"$KEEP_FILE"
fi

# Exact shape of a rebuildable project dependency folder: it must sit next to
# its manifest AND lockfile (so one install command restores it), inside your
# home folder but outside Library and dot-folders, and must not be a symlink.
dep_ok() {
  local p="${1%/}" parent name
  name="${p##*/}"; parent="${p%/*}"
  [[ "$p" == "$HOME"/?* && "$p" != "$HOME/Library/"* && "$p" != "$HOME/."* ]] || return 1
  case "$p" in */node_modules/*|*/vendor/*|*/target/*|*/.git/*) return 1 ;; esac
  [[ -d "$p" && ! -L "$p" && -d "$parent" && ! -L "$parent" ]] || return 1
  case "$name" in
    node_modules) [[ -f "$parent/package.json" ]] || return 1
                  [[ -f "$parent/package-lock.json" || -f "$parent/yarn.lock" || -f "$parent/pnpm-lock.yaml" \
                     || -f "$parent/bun.lockb" || -f "$parent/bun.lock" ]] ;;
    vendor)       [[ -f "$parent/composer.json" && -f "$parent/composer.lock" ]] ;;
    target)       [[ -f "$parent/pom.xml" ]] ;;
    *)            return 1 ;;
  esac
}

project_stale() {   # project_stale <dir> <days>: nothing in it changed for that long (deps excluded)
  local d="$1" days="$2" recent
  recent="$(find "$d" \( -name node_modules -o -name vendor -o -name target \) -prune -o \
              -type f -mtime -"$days" -print 2>/dev/null | head -n 1)"
  [[ -z "$recent" ]]
}

guard_path() {
  local p="${1%/}" r k i inside=false
  [[ -n "$p" && "$p" == /* ]] || return 1
  case "$p" in *"/.."*|*"/./"*|*"//"*|*$'\n'*) return 1 ;; esac
  for (( i=0; i<${#KEEP[@]}; i++ )); do
    k="${KEEP[i]}"
    if [[ "$k" == /* ]]; then
      [[ "$p" == "$k" || "$p" == "$k"/* || "$k" == "$p"/* ]] && return 1
    else
      [[ "$p" == */"$k" || "$p" == */"$k"/* ]] && return 1
    fi
  done
  dep_ok "$p" && return 0
  for r in "${ALLOWED_ROOTS[@]}"; do
    [[ "$p" == "$r"/?* ]] && { inside=true; break; }
  done
  $inside || return 1

  # Things that live under "cache" roots but are NOT disposable.
  case "$p" in
    *"/virtualenvs"*|*"/LocalHistory"*|*"/MobileSync"*|*"/Mobile Documents"*|*"/Keychains"*) return 1 ;;
    # Browser profiles (logins, passkeys, extensions): only the web cache under ~/Library/Caches may be cleaned.
    "$HOME/Library/Application Support/Google/"*|"$HOME/Library/Application Support/Microsoft Edge/"*|\
    "$HOME/Library/Application Support/BraveSoftware/"*|"$HOME/Library/Application Support/Firefox/"*|\
    "$HOME/Library/Application Support/Arc/"*|"$HOME/Library/Application Support/Chromium/"*|\
    "$HOME/Library/Application Support/Vivaldi/"*|"$HOME/Library/Application Support/com.operasoftware."*|\
    "$HOME/Library/Application Support/Opera"*|\
    "$HOME/Library/Safari/"*|"$HOME/Library/Containers/"*|"$HOME/Library/Group Containers/"*) return 1 ;;
    # Any Chromium-style profile folder, whatever the browser is called.
    "$HOME/Library/Application Support/"*"/Default/"*|"$HOME/Library/Application Support/"*"/Profile "*) return 1 ;;
    # Sign-ins, sessions, saved passwords and passkeys: never, wherever they are.
    *"/Cookies"*|*"/Login Data"*|*"/Local Storage"*|*"/Session Storage"*|*"/IndexedDB"*|*"/WebAuthn"*|*"/Web Data"*|*"/Passwords"*|*"/databases"*) return 1 ;;
    "$HOME/Library/Caches/pypoetry"|"$HOME/Library/Caches/JetBrains"|"$HOME/Library/Caches/JetBrains/"*) return 1 ;;
    "$HOME/Library/Caches/com.apple."*)
      [[ "$p" == "$HOME/Library/Caches/com.apple.dt."* ]] || return 1 ;;
  esac

  # Application Support holds real app data. Only Chromium/Electron cache
  # folders, identified by exact name, may go.
  if [[ "$p" == "$HOME/Library/Application Support/"* ]]; then
    case "${p##*/}" in
      Cache|"Code Cache"|GPUCache|CachedData|DawnCache|DawnGraphiteCache|DawnWebGPUCache|ShaderCache|GrShaderCache|logs) ;;
      *) return 1 ;;
    esac
  fi
  # Inside dot-dirs only the known cache sub-folders.
  case "$p" in
    "$HOME/.gradle/"*)   case "$p" in "$HOME/.gradle/caches"|"$HOME/.gradle/wrapper/dists"|"$HOME/.gradle/daemon"|"$HOME/.gradle/notifications") ;; *) return 1 ;; esac ;;
    "$HOME/.composer/"*) [[ "$p" == "$HOME/.composer/cache" ]] || return 1 ;;
    "$HOME/.ivy2/"*)     [[ "$p" == "$HOME/.ivy2/cache" ]] || return 1 ;;
    "$HOME/.npm/"*)      case "$p" in "$HOME/.npm/_cacache"|"$HOME/.npm/_logs"|"$HOME/.npm/_npx") ;; *) return 1 ;; esac ;;
    "$HOME/.cache/"*)    case "$p" in "$HOME/.cache/pip"|"$HOME/.cache/uv"|"$HOME/.cache/yarn"|"$HOME/.cache/pypoetry/cache"|"$HOME/.cache/pypoetry/artifacts") ;; *) return 1 ;; esac ;;
    "$HOME/.bun/install/"*)  [[ "$p" == "$HOME/.bun/install/cache" ]] || return 1 ;;
    "$HOME/.yarn/berry/"*)   [[ "$p" == "$HOME/.yarn/berry/cache" ]] || return 1 ;;
    "$HOME/.pub-cache/"*)    [[ "$p" == "$HOME/.pub-cache/hosted" ]] || return 1 ;;
    "$HOME/.conda/"*|"$HOME/miniconda3/"*|"$HOME/anaconda3/"*|"$HOME/miniforge3/"*|"$HOME/mambaforge/"*|"$HOME/micromamba/"*)
      # Conda/Mamba: only the downloaded-package cache. Never envs/, the base environment or anything else.
      case "$p" in "$HOME/.conda/pkgs"|"$HOME/miniconda3/pkgs"|"$HOME/anaconda3/pkgs"|"$HOME/miniforge3/pkgs"|"$HOME/mambaforge/pkgs"|"$HOME/micromamba/pkgs") ;; *) return 1 ;; esac ;;
    "$HOME/.cargo/registry/"*) case "$p" in "$HOME/.cargo/registry/cache"|"$HOME/.cargo/registry/src") ;; *) return 1 ;; esac ;;
  esac
  return 0
}

# Snapshot of every file currently open by your processes, and running apps.
LSOF_SNAP="$(mktemp "${TMPDIR:-/tmp}/wisp_lsof.XXXXXX")"
LOCK_DIR="${TMPDIR:-/tmp}/wisp.lock"; HAVE_LOCK=false
cleanup() { rm -f "$LSOF_SNAP"; $HAVE_LOCK && rm -rf "$LOCK_DIR"; return 0; }
trap cleanup EXIT
trap 'echo; warn "Interrupted. Anything already removed was regenerable."; emit ERROR interrupted; exit 130' INT TERM HUP

acquire_lock() {   # one run at a time
  local pid
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      err "Another clean is already running (pid $pid)."; emit ERROR busy; exit 1
    fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null || { err "Cannot create lock."; exit 1; }
  fi
  echo $$ >"$LOCK_DIR/pid"; HAVE_LOCK=true
}
RUNNING_IDS=""; RUNNING_NAMES=""

snapshot_activity() {
  lsof -n -P -Fn 2>/dev/null | grep '^n/' | sort -u >"$LSOF_SNAP" 2>/dev/null || true
  local apps; apps="$(lsappinfo list 2>/dev/null || true)"
  RUNNING_IDS="$(printf '%s\n' "$apps" | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' | sort -u)"
  RUNNING_NAMES="$(printf '%s\n' "$apps" | sed -n 's/^ *[0-9]*) "\(.*\)" ASN:.*/\1/p' | sort -u)"
}

in_use() { [[ -s "$LSOF_SNAP" ]] && grep -qF "n${1%/}/" "$LSOF_SNAP"; }

bundle_running() { [[ -n "$RUNNING_IDS" ]] && printf '%s\n' "$RUNNING_IDS" | grep -qixF "$1"; }

# Does a cache folder name belong to a running app (by bundle id or app name)?
app_running() {
  local b="$1" id
  bundle_running "$b" && return 0
  [[ -n "$RUNNING_NAMES" ]] && printf '%s\n' "$RUNNING_NAMES" | grep -qixF "$b" && return 0
  while IFS= read -r id; do                      # com.foo.app.ShipIt → com.foo.app
    [[ -n "$id" && "$b" == "$id".* ]] && return 0
  done <<<"$RUNNING_IDS"
  return 1
}

# ── Action primitives (the ONLY code that changes anything) ──────────────────
FREED_KB=0

nuke() {   # nuke <path> <size_kb>
  local p="${1%/}" kb="${2:-0}" left
  if ! guard_path "$p" || [[ -L "$p" ]]; then err "refused (outside allowlist): $p"; return 1; fi
  if $DRY_RUN; then FREED_KB=$(( FREED_KB + kb )); return 0; fi
  rm -rf -- "$p" 2>/dev/null
  if [[ -e "$p" ]]; then
    left=$(size_kb "$p")
    (( kb > left )) && FREED_KB=$(( FREED_KB + kb - left ))
    warn "partly removed (in use or protected): $(pretty "$p")"
  else
    FREED_KB=$(( FREED_KB + kb ))
    printf '%s\n' "removed $p" >>"$LOG_FILE"
  fi
}

old_files_kb() {   # old_files_kb <root> <days>
  find "$1" -type f -mtime +"$2" -exec stat -f '%z' {} + 2>/dev/null |
    awk '{s+=$1} END{print int(s/1024)}'
}

prune_old() {   # prune_old <root> <days> <size_kb>: regular files only
  local root="${1%/}" days="$2" kb="${3:-0}"
  if ! guard_path "$root/x" || [[ -L "$root" ]]; then err "refused: $root"; return 1; fi
  FREED_KB=$(( FREED_KB + kb ))
  $DRY_RUN && return 0
  find "$root" -type f -mtime +"$days" -delete 2>/dev/null || true
}

run_cmd() {   # run_cmd <cmd> [args…]
  if $DRY_RUN; then note "[dry-run] would run: $*"; return 0; fi
  note "running: $*"
  "$@" >>"$LOG_FILE" 2>&1 || warn "'$1' reported a problem (details in log)"
}

want() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

confirm() {   # confirm <prompt> <default y|n>   (category = CAT_ID)
  local prompt="$1" def="${2:-n}" ans hint="[y/N]"
  if [[ -n "$ONLY" ]]; then want "$CAT_ID"; return; fi   # the app names exactly what to clean
  if $APP_MODE && $DRY_RUN; then return 0; fi            # app scan: list every category
  if $ASSUME_YES; then [[ "$def" == y ]]; return; fi     # also makes --dry-run --yes an exact preview
  $DRY_RUN && return 0
  [[ "$def" == y ]] && hint="[Y/n]"
  printf '%s' "  ${YELLOW}▶${RESET} ${prompt} ${hint} "
  read -r ans </dev/tty 2>/dev/null || { echo; return 1; }   # no terminal → no
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# ── Candidate list for the current section ───────────────────────────────────
S_PATHS=(); S_KB=(); S_TOTAL=0; S_BUSY=0; S_BUSY_NAMES=""
MIN_KB=512    # ignore crumbs smaller than this

reset_list() { S_PATHS=(); S_KB=(); S_TOTAL=0; S_BUSY=0; S_BUSY_NAMES=""; }

add() {   # add <path>: queue for deletion if it exists, is allowed and idle
  local p="${1%/}" kb
  [[ -e "$p" && ! -L "$p" ]] || return 0
  guard_path "$p" || return 0
  if in_use "$p"; then S_BUSY=$(( S_BUSY + 1 )); return 0; fi
  kb=$(size_kb "$p")
  (( kb >= MIN_KB )) || return 0
  S_PATHS+=("$p"); S_KB+=("$kb"); S_TOTAL=$(( S_TOTAL + kb ))
}

CAT_ID=""; CAT_TITLE=""; CAT_RISK="safe"; CAT_SYMBOL="questionmark"; CAT_DESC=""
cat_begin() {   # cat_begin <id> <title> <risk> <sf-symbol> <description>
  CAT_ID="$1"; CAT_TITLE="$2"; CAT_RISK="$3"; CAT_SYMBOL="$4"; CAT_DESC="$5"; reset_list
}
emit_cat() { emit CAT "$CAT_ID" "$CAT_TITLE" "$CAT_RISK" "$1" "$2" "$CAT_SYMBOL" "$CAT_DESC"; }

offer() {   # offer <prompt> <default y|n>: show the list, ask, delete
  local prompt="$1" def="${2:-n}" n=${#S_PATHS[@]} i shown=12 before
  if (( S_BUSY > 0 )); then
    note "skipped $S_BUSY in use right now${S_BUSY_NAMES:+: ${S_BUSY_NAMES}}"
    [[ -n "$S_BUSY_NAMES" ]] && emit BUSY "$S_BUSY_NAMES"
  fi
  if (( n == 0 )); then note "nothing worth cleaning here"; reset_list; return 1; fi

  for (( i=0; i<n; i++ )); do printf '%s\t%s\n' "${S_KB[i]}" "${S_PATHS[i]}"; done |
    sort -rn | head -n "$shown" |
    while IFS=$'\t' read -r kb p; do info "$(printf '%10s' "$(human "$kb")")  $(pretty "$p")"; done
  (( n > shown )) && note "            … and $(( n - shown )) smaller items"
  info "${BOLD}$(printf '%10s' "$(human "$S_TOTAL")")  total${RESET}"

  if $APP_MODE; then
    emit_cat "$S_TOTAL" "$def"
    for (( i=0; i<n; i++ )); do emit ITEM "$CAT_ID" "${S_KB[i]}" "${S_PATHS[i]}"; done
  fi

  if confirm "$prompt" "$def"; then
    before=$FREED_KB
    for (( i=0; i<n; i++ )); do nuke "${S_PATHS[i]}" "${S_KB[i]}"; done
    if $DRY_RUN; then note "[dry-run] would remove $(human "$S_TOTAL")"; else ok "done"; fi
    emit CATDONE "$CAT_ID" "$(( FREED_KB - before ))"
    reset_list; return 0
  fi
  note "skipped"; reset_list; return 1
}

# =============================================================================
#  SELF-TEST  (--self-test): exercises the real code paths on throwaway data
# =============================================================================
self_test() {
  local fails=0 p sb victim link logs n_ref=0
  check() { if "$@"; then :; else err "FAILED: $*"; fails=$(( fails + 1 )); fi; }
  # shellcheck disable=SC2329  # called through check()
  refuses() { ! guard_path "$1"; }
  # shellcheck disable=SC2329
  gone() { [[ ! -e "$1" ]]; }

  section "Self-test 1/7: guard refuses everything important"
  for p in "" "/" "/etc" "$HOME" "$HOME/Documents" "$HOME/Documents/x" "$HOME/Desktop/x" \
           "$HOME/Library" "$HOME/Library/Caches" "$HOME/Library/Caches/../Documents" \
           "$HOME/Library/Caches/a/../../Mail" "$HOME/Library/Application Support/Code/User" \
           "$HOME/Library/Application Support/Google/Chrome" "$HOME/Library/Keychains/x" \
           "$HOME/Library/Caches/pypoetry" "$HOME/Library/Caches/pypoetry/virtualenvs/a" \
           "$HOME/Library/Caches/JetBrains/X" "$HOME/Library/Caches/com.apple.bird" \
           "$HOME/.gradle/gradle.properties" "$HOME/.npm/x" "$HOME/.cache/huggingface" \
           "$HOME/.ssh/id_rsa" "$HOME/.composer/auth.json" "$HOME/.cargo/registry/index" \
           "$HOME/Library/Application Support/MobileSync/Backup" "relative/path" \
           "$HOME/Library/Developer/Xcode/Archives/x" \
           "$HOME/Library/Application Support/Google/Chrome/Default" \
           "$HOME/Library/Application Support/Google/Chrome/Default/Cookies" \
           "$HOME/Library/Application Support/Google/Chrome/Default/Login Data" \
           "$HOME/Library/Application Support/Google/Chrome/Default/Local Storage" \
           "$HOME/Library/Application Support/Google/Chrome/Default/IndexedDB" \
           "$HOME/Library/Application Support/Slack/Cookies" \
           "$HOME/Library/Application Support/Slack/Local Storage" \
           "$HOME/Library/Caches/SomeApp/Cookies" \
           "$HOME/Library/Cookies/Cookies.binarycookies" \
           "$HOME/Library/Keychains/login.keychain-db" \
           "$HOME/Library/Safari/History.db" "$HOME/Library/Passes/x" "$HOME/Pictures/x" "$HOME/Downloads/x" \
           "$HOME/Library/Application Support/Google/Chrome/Default/Cache" \
           "$HOME/Library/Application Support/Google/Chrome/Default/Code Cache" \
           "$HOME/Library/Application Support/Microsoft Edge/Default/Cache" \
           "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default/GPUCache" \
           "$HOME/Library/Application Support/Firefox/Profiles/x.default/cache2" \
           "$HOME/Library/Application Support/Vivaldi/Default/Cache" \
           "$HOME/Library/Application Support/com.operasoftware.Opera/Default/Cookies" \
           "$HOME/Library/Application Support/SomeNewBrowser/Default/Cache" \
           "$HOME/Library/Application Support/SomeNewBrowser/Profile 1/GPUCache" \
           "$HOME/Library/Containers/com.apple.mail/Data/Library/Caches/x" \
           "$HOME/Projects/app/node_modules" "$HOME/Projects/app/src"; do
    check refuses "$p"; n_ref=$(( ${n_ref:-0} + 1 ))
  done
  ok "$n_ref dangerous paths refused (documents, keychains/passkeys, browser logins, cookies, backups…)"

  section "Self-test 2/7: guard allows real cache locations"
  for p in "$HOME/Library/Caches/Yarn" "$HOME/Library/Application Support/Code/Cache" \
           "$HOME/.gradle/caches" "$HOME/.npm/_cacache" "$HOME/.cache/pip"            "$HOME/.pub-cache/hosted" "$HOME/.conda/pkgs" "$HOME/miniconda3/pkgs" "$HOME/anaconda3/pkgs"            "$HOME/miniforge3/pkgs" "$HOME/mambaforge/pkgs" "$HOME/micromamba/pkgs" \
           "$HOME/Library/Developer/Xcode/DerivedData/App-abc"; do
    check guard_path "$p"
  done
  KEEP=("$HOME/Library/Caches/Yarn" "Code")
  check refuses "$HOME/Library/Caches/Yarn"
  check refuses "$HOME/Library/Caches/Yarn/v6"
  check refuses "$HOME/Library/Application Support/Code/Cache"
  KEEP=()
  ok "cache paths allowed; keep-list entries refused"

  section "Self-test 3/7: dry-run deletes nothing, real run deletes"
  sb="$HOME/Library/Caches/wisp_selftest.$$"
  mkdir -p "$sb/sub" && dd if=/dev/zero of="$sb/sub/blob" bs=1024 count=2048 2>/dev/null
  DRY_RUN=true;  nuke "$sb" 2048; check test -f "$sb/sub/blob"
  exec 9>"$sb/open.file"; snapshot_activity
  check in_use "$sb"                                   # open file is detected
  reset_list; add "$sb"; check test "${#S_PATHS[@]}" -eq 0   # …so it is not queued
  exec 9>&-; snapshot_activity
  reset_list; add "$sb"; check test "${#S_PATHS[@]}" -eq 1
  DRY_RUN=false; nuke "$sb" 2048; check gone "$sb"
  ok "dry-run kept the folder, in-use detection worked, real run removed it"

  section "Self-test 4/7: symlinks are never followed"
  victim="$HOME/Library/Caches/wisp_selftest_victim.$$"; link="$HOME/Library/Caches/wisp_selftest_link.$$"
  mkdir -p "$victim" && : >"$victim/precious" && ln -s "$victim" "$link"
  reset_list; add "$link"; check test "${#S_PATHS[@]}" -eq 0
  nuke "$link" 0 >/dev/null 2>&1
  check test -f "$victim/precious"
  rm -f "$link"; rm -rf "$victim"
  ok "symlink refused, target untouched"

  section "Self-test 5/7: log pruning removes only old files"
  logs="$HOME/Library/Logs/Wisp_selftest.$$"
  mkdir -p "$logs" && : >"$logs/new.log" && : >"$logs/old.log" && touch -t 202001010000 "$logs/old.log"
  DRY_RUN=true;  prune_old "$logs" 7 0; check test -f "$logs/old.log"
  DRY_RUN=false; prune_old "$logs" 7 0
  check gone "$logs/old.log"; check test -f "$logs/new.log"
  rm -rf "$logs"
  ok "old log removed, recent log kept"

  section "Self-test 6/7: project dependencies need manifest + lockfile + idle project"
  local proj="$HOME/wisp_selftest_proj.$$"
  mkdir -p "$proj/node_modules/pkg" "$proj/vendor" "$proj/target"
  check refuses "$proj/node_modules"                    # no package.json
  : >"$proj/package.json"; check refuses "$proj/node_modules"   # no lockfile
  : >"$proj/package-lock.json"; check guard_path "$proj/node_modules"
  check refuses "$proj/node_modules/pkg"                # only the top folder
  check refuses "$proj/vendor"; touch "$proj/composer.json" "$proj/composer.lock"; check guard_path "$proj/vendor"
  check refuses "$proj/target"; : >"$proj/pom.xml"; check guard_path "$proj/target"
  check refuses "$proj"; check refuses "$proj/package.json"
  mv "$proj/node_modules" "$proj/node_modules.real"; ln -s "$proj/node_modules.real" "$proj/node_modules"
  check refuses "$proj/node_modules"                    # symlinked folder
  rm -f "$proj/node_modules"; mv "$proj/node_modules.real" "$proj/node_modules"
  if project_stale "$proj" 2; then err "FAILED: a just-created project counted as idle"; fails=$(( fails + 1 )); fi
  touch -t 202001010000 "$proj" "$proj/package.json" "$proj/package-lock.json" "$proj/composer.json" "$proj/composer.lock" "$proj/pom.xml"
  check project_stale "$proj" 90
  DRY_RUN=true;  nuke "$proj/node_modules" 1; check test -d "$proj/node_modules"
  DRY_RUN=false; nuke "$proj/node_modules" 1; check gone "$proj/node_modules"; check test -f "$proj/package.json"
  rm -rf "$proj"
  ok "dependency folders deleted only when rebuildable and idle; project files untouched"

  section "Self-test 7/7: category selection (--only)"
  ONLY="browsers,logs"; CAT_ID=browsers; check want browsers; CAT_ID=appcaches; check test "$(want appcaches && echo y || echo n)" = n
  check test "$(confirm x y && echo y || echo n)" = n
  CAT_ID=logs; check test "$(confirm x n && echo y || echo n)" = y
  ONLY=""
  ok "only the named categories are allowed to run"

  log ""
  if (( fails == 0 )); then log "${GREEN}${BOLD}All self-tests passed.${RESET}"; exit 0; fi
  log "${RED}${BOLD}$fails self-test check(s) FAILED. Do not use this script until fixed.${RESET}"; exit 1
}
$SELF_TEST && self_test

# =============================================================================
#  INSIGHTS  (--insights): read-only listing of large files and big things never deleted
# =============================================================================
report() {   # report <path> <advice>: only mentioned if >= 100 MB
  [[ -e "$1" ]] || return 0
  local kb; kb=$(size_kb "$1")
  (( kb >= 102400 )) || return 0
  emit HINT "$kb" "$1" "$2"
  info "$(printf '%10s' "$(human "$kb")")  $(pretty "$1")"
  note "            → $2"
}

report_items() {
  report "$HOME/Library/Application Support/MobileSync/Backup" "iPhone/iPad backups. Manage in Finder → your device → Manage Backups."
  report "$HOME/Library/Developer/Xcode/Archives"              "Xcode archives. Delete old ones in Xcode → Window → Organizer."
  report "$HOME/Library/Developer/CoreSimulator/Devices"       "Simulator devices. Remove unused ones in Xcode → Window → Devices and Simulators."
  report "$HOME/Library/Caches/JetBrains"                      "JetBrains caches + Local History. Use the IDE: File → Invalidate Caches."
  report "$HOME/.m2/repository"                                "Maven repo (may hold locally-installed artifacts). Prune by hand if needed."
  report "$HOME/.pyenv/versions"                               "pyenv Pythons. Remove unused ones with 'pyenv uninstall <version>'."
  report "$HOME/.nvm/versions"                                 "nvm Node versions. Remove unused ones with 'nvm uninstall <version>'."
  report "$HOME/Library/Caches/ms-playwright"                  "Playwright browsers. 'npx playwright uninstall --all' if unused."
  report "$HOME/.cache/huggingface"                            "Hugging Face models. 'huggingface-cli delete-cache' to pick what to drop."
  report "$HOME/.ollama/models"                                "Ollama models. 'ollama rm <model>' for ones you no longer use."
  report "$HOME/Library/Containers/com.docker.docker/Data/vms" "Docker disk image. Shrink in Docker Desktop → Settings → Resources."
}

big_files() {   # prints "kb<TAB>kind<TAB>path", biggest first. kind: user | app
  have mdfind || return 0
  mdfind -onlyin "$HOME" 'kMDItemFSSize > 262144000' 2>/dev/null |
    while IFS= read -r f; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      case "$f" in */.Trash/*|*/node_modules/*) continue ;; esac
      k=user; case "$f" in "$HOME/Library/"*|"$HOME/."*) k=app ;; esac
      b=$(stat -f '%b' "$f" 2>/dev/null) || continue
      printf '%s\t%s\t%s\n' "$(( b / 2 ))" "$k" "$f"
    done | sort -rn | head -n 40
}

insights() {
  local kb k f
  while IFS=$'\t' read -r kb k f; do emit BIG "$kb" "$k" "$f"; done < <(big_files)
  report_items
  emit DONE
  exit 0
}
$INSIGHTS && insights

acquire_lock

# =============================================================================
#  START
# =============================================================================
STEP=0; TOTAL_STEPS=12; $APP_MODE && TOTAL_STEPS=11
step() { STEP=$(( STEP + 1 )); section "$STEP. $*"; emit STEP "$STEP" "$TOTAL_STEPS"; }

log ""
log "${BOLD}Wisp v${VERSION}${RESET}  ${DIM}$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) · $(uname -m)${RESET}"
$DRY_RUN && log "${YELLOW}DRY-RUN: nothing will be deleted.${RESET}"
[[ -n "$ONLY" ]] && note "only: $ONLY"
note "log: $(pretty "$LOG_FILE")"
note "Tip: quit apps you want cleaned. Caches of running apps are skipped."

FREE_BEFORE=$(free_kb)
info "Free disk space now: ${BOLD}$(human "$FREE_BEFORE")${RESET}"
note "checking what is currently in use…"
snapshot_activity

busy_add() { S_BUSY=$(( S_BUSY + 1 )); S_BUSY_NAMES="${S_BUSY_NAMES}${S_BUSY_NAMES:+, }$1"; }

browser_bundle() {   # folder name → bundle id; empty when it is not a browser
  case "$1" in
    Google|com.google.Chrome*)                echo com.google.Chrome ;;
    "Microsoft Edge"|com.microsoft.edgemac*)  echo com.microsoft.edgemac ;;
    BraveSoftware|com.brave.Browser*)         echo com.brave.Browser ;;
    Firefox|org.mozilla.*)                    echo org.mozilla.firefox ;;
    Arc|company.thebrowser.Browser*)          echo company.thebrowser.Browser ;;
    com.operasoftware.*|com.vivaldi.*|Chromium) echo "$1" ;;
  esac
}
friendly() {
  case "$1" in
    Google) echo "Google Chrome" ;; BraveSoftware) echo "Brave" ;; org.mozilla.*) echo "Firefox" ;;
    *) echo "$1" ;;
  esac
}

# ── 1 · Browser caches ───────────────────────────────────────────────────────
step "Browser caches"
cat_begin browsers "Browser caches" safe globe \
  "Web page cache only. Sign-ins, passkeys, saved passwords, history and bookmarks are never touched."
for d in "$HOME/Library/Caches"/*/; do
  [[ -d "$d" ]] || continue
  d="${d%/}"; base="${d##*/}"
  b="$(browser_bundle "$base")"; [[ -n "$b" ]] || continue
  if bundle_running "$b" || app_running "$base"; then busy_add "$(friendly "$base")"; continue; fi
  add "$d"
done
offer "Clear browser caches?" y

# ── 2 · App caches ───────────────────────────────────────────────────────────
step "App caches"
note "Apps rebuild these on demand. Apple system caches and running apps are left alone."

cache_skip() {
  case "$1" in
    com.apple.dt.*) return 1 ;;                         # Xcode caches are fine
    com.apple.*|CloudKit|FamilyCircle|GeoServices|PassKit) return 0 ;;   # system-managed
    JetBrains)   return 0 ;;   # contains IDE Local History
    pypoetry)    return 0 ;;   # contains Poetry virtualenvs
    Homebrew)    return 0 ;;   # handled by brew itself
    ms-playwright|Cypress|*huggingface*|*torch*|*ollama*|*[Mm]odels*) return 0 ;;  # large downloads
  esac
  return 1
}

cat_begin appcaches "App caches" safe square.stack.3d.up \
  "Temporary files that apps rebuild by themselves. Apple's own system caches are left alone."
for d in "$HOME/Library/Caches"/*/; do
  [[ -d "$d" ]] || continue
  d="${d%/}"; base="${d##*/}"
  cache_skip "$base" && continue
  [[ -n "$(browser_bundle "$base")" ]] && continue
  if app_running "$base"; then S_BUSY=$(( S_BUSY + 1 )); continue; fi   # cache folder names are not app names
  add "$d"
done
offer "Clear these app caches?" y

# ── 3 · Electron / Chromium app caches ───────────────────────────────────────
step "App & editor caches (VS Code, Cursor, Slack, Teams, Discord…)"
note "Only Cache / Code Cache / GPUCache-style folders. Settings, extensions and workspaces are untouched."
cat_begin electron "Editor & chat-app caches" safe macwindow \
  "VS Code, Cursor, Slack, Docker Desktop… Only their cache folders; settings, extensions and workspaces stay."
for d in "$HOME/Library/Application Support"/*/; do
  [[ -d "$d" ]] || continue
  d="${d%/}"
  [[ -n "$(browser_bundle "${d##*/}")" ]] && continue          # browsers are handled (and protected) elsewhere
  [[ -d "$d/Code Cache" || -d "$d/GPUCache" ]] || continue     # Chromium signature
  if in_use "$d" || app_running "${d##*/}"; then busy_add "${d##*/}"; continue; fi
  for sub in Cache "Code Cache" GPUCache CachedData DawnCache DawnGraphiteCache DawnWebGPUCache ShaderCache GrShaderCache logs; do
    add "$d/$sub"
  done
done
offer "Clear these Electron caches?" y

# ── 4 · Logs & crash reports ─────────────────────────────────────────────────
step "Logs & crash reports older than ${LOG_DAYS} days"
cat_begin logs "Old logs & crash reports" safe doc.text \
  "Log files older than ${LOG_DAYS} days. Recent logs stay in case you need them."
if [[ -d "$HOME/Library/Logs" ]]; then
  kb=$(old_files_kb "$HOME/Library/Logs" "$LOG_DAYS")
  if (( kb >= MIN_KB )); then
    info "$(printf '%10s' "$(human "$kb")")  ~/Library/Logs (old files only; recent logs kept)"
    emit_cat "$kb" y
    emit ITEM "$CAT_ID" "$kb" "$HOME/Library/Logs (files older than ${LOG_DAYS} days)"
    if confirm "Delete old user logs?" y; then
      before=$FREED_KB
      prune_old "$HOME/Library/Logs" "$LOG_DAYS" "$kb"
      if $DRY_RUN; then note "[dry-run] would remove $(human "$kb")"; else ok "done"; fi
      emit CATDONE "$CAT_ID" "$(( FREED_KB - before ))"
    fi
  else
    note "nothing worth cleaning here"
  fi
fi
if $SYSTEM; then
  cat_begin syslogs "System logs" safe doc.text "Needs your password."
  note "system logs need sudo, you may be asked for your password"
  if confirm "Delete system crash reports and rotated system logs older than ${LOG_DAYS} days?" y; then
    run_cmd sudo find /Library/Logs/DiagnosticReports -type f -mtime +"$LOG_DAYS" -delete
    run_cmd sudo find /private/var/log -type f \( -name '*.gz' -o -name '*.bz2' -o -name '*.[0-9]' \) -mtime +"$LOG_DAYS" -delete
  fi
fi

# ── 5 · Xcode ────────────────────────────────────────────────────────────────
step "Xcode build data"
if [[ -d "$HOME/Library/Developer/Xcode" || -d "$HOME/Library/Developer/CoreSimulator" ]]; then
  note "Archives (needed to symbolicate shipped builds) are never touched."
  cat_begin xcode "Xcode build data" rebuild hammer \
    "DerivedData and simulator caches. Your next build is a full rebuild. Archives are never touched."
  if bundle_running com.apple.dt.Xcode; then
    warn "Xcode is running. Quit it to clean DerivedData."; busy_add "Xcode"
    emit BUSY "$S_BUSY_NAMES"; reset_list
  else
    for d in "$HOME/Library/Developer/Xcode/DerivedData"/*/; do [[ -d "$d" ]] && add "$d"; done
    for d in "$HOME/Library/Developer/CoreSimulator/Caches"/*/; do [[ -d "$d" ]] && add "$d"; done
    offer "Delete DerivedData and simulator caches? (next build is a full rebuild)" y
  fi

  cat_begin devsupport "Device support symbols" redownload iphone \
    "Debug symbols for iOS/watchOS/tvOS devices. Re-created (a few minutes) the next time you connect a device."
  for kind in iOS watchOS tvOS; do
    for d in "$HOME/Library/Developer/Xcode/$kind DeviceSupport"/*/; do [[ -d "$d" ]] && add "$d"; done
  done
  offer "Delete DeviceSupport symbols?" n

  if xcode-select -p >/dev/null 2>&1 && xcrun --find simctl >/dev/null 2>&1; then
    cat_begin simulators "Unavailable simulators" safe cube \
      "Simulators whose runtime is no longer installed."
    emit_cat -1 y
    if confirm "Delete simulators whose runtime is no longer installed?" y; then
      run_cmd xcrun simctl delete unavailable; emit CATDONE "$CAT_ID" 0
    fi
  fi
else
  note "Xcode not found, skipped"
fi

# ── 6 · Package-manager download caches ──────────────────────────────────────
step "Package caches (npm · yarn · bun · pip · uv · Poetry · Composer · Ivy)"
note "Downloaded packages only. Installed packages, node_modules and virtualenvs are untouched."
cat_begin pkgcaches "Package download caches" safe shippingbox \
  "npm, Yarn, Bun, pip, uv, Poetry, Composer, Ivy. Re-downloaded only when a project needs them again."
add "$HOME/.npm/_cacache"
add "$HOME/.npm/_logs"
add "$HOME/.npm/_npx"
add "$HOME/.cache/yarn"
add "$HOME/.yarn/berry/cache"
add "$HOME/.bun/install/cache"
add "$HOME/.cache/pip"
add "$HOME/.cache/uv"
add "$HOME/.cache/pypoetry/cache"
add "$HOME/.cache/pypoetry/artifacts"
add "$HOME/Library/Caches/pypoetry/cache"
add "$HOME/Library/Caches/pypoetry/artifacts"
add "$HOME/.composer/cache"
add "$HOME/.ivy2/cache"
add "$HOME/.gradle/daemon"
add "$HOME/.gradle/notifications"
offer "Clear these package caches? (re-downloaded when needed)" y

if have pnpm; then
  cat_begin pnpm "pnpm store" safe shippingbox "Removes only packages that no project references any more."
  emit_cat -1 y
  if confirm "Run 'pnpm store prune'? (removes only packages no project references)" y; then
    run_cmd pnpm store prune; emit CATDONE "$CAT_ID" 0
  fi
fi

# ── 7 · Large dependency stores (costly to rebuild → default No) ─────────────
step "Large dependency stores (Gradle · Cargo)"
cat_begin depstores "Gradle & Cargo stores" redownload externaldrive \
  "Safe to delete, but your next build re-downloads everything and will not work offline."
if pgrep -f GradleDaemon >/dev/null 2>&1; then
  warn "A Gradle daemon is running. Gradle caches skipped (run 'gradle --stop' first)."; busy_add "Gradle"
else
  add "$HOME/.gradle/caches"
  add "$HOME/.gradle/wrapper/dists"
fi
add "$HOME/.cargo/registry/cache"
add "$HOME/.cargo/registry/src"
offer "Delete these dependency stores?" n

# ── 7b · Dart/Flutter and Conda download caches (re-downloaded → default No) ─
step "Dart/Flutter and Conda package caches"
note "Downloaded packages only. Conda environments, SDKs, activated Dart tools and your projects are untouched."
cat_begin devcaches "Dart & Conda package caches" redownload shippingbox   "Dart/Flutter pub cache and Conda/Mamba package cache. Re-downloaded by 'pub get' / 'conda install'; environments are untouched."
add "$HOME/.pub-cache/hosted"
add "$HOME/.conda/pkgs"
add "$HOME/miniconda3/pkgs"
add "$HOME/anaconda3/pkgs"
add "$HOME/miniforge3/pkgs"
add "$HOME/mambaforge/pkgs"
add "$HOME/micromamba/pkgs"
offer "Clear the Dart and Conda package caches? (re-downloaded when needed)" n

# ── 8 · Homebrew ─────────────────────────────────────────────────────────────
step "Homebrew"
if have brew; then
  export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
  bc="$(brew --cache 2>/dev/null || true)"; bkb=0
  [[ -n "$bc" && -d "$bc" ]] && bkb=$(size_kb "$bc")
  info "$(printf '%10s' "$(human "$bkb")")  download cache"
  cat_begin brew "Homebrew cleanup" safe cup.and.saucer \
    "Old versions and downloads of formulae. Everything you have installed stays installed."
  emit_cat "$bkb" y
  if confirm "Run 'brew cleanup --prune=all'? (old versions + downloads; installed software stays)" y; then
    run_cmd brew cleanup --prune=all; emit CATDONE "$CAT_ID" "$bkb"
  fi
  orphans="$(brew autoremove --dry-run 2>/dev/null | grep -v '^==>' || true)"
  if [[ -n "$orphans" ]]; then
    cat_begin brewauto "Unused Homebrew dependencies" review shippingbox \
      "Installed only as dependencies and no longer needed by anything. Check the list first."
    info "Formulae installed only as dependencies and no longer needed by anything:"
    emit_cat -1 n
    printf '%s\n' "$orphans" | while IFS= read -r l; do info "    $l"; emit ITEM "$CAT_ID" 0 "$l"; done
    if confirm "Uninstall them with 'brew autoremove'? (check the list first)" n; then
      run_cmd brew autoremove; emit CATDONE "$CAT_ID" 0
    fi
  fi
else
  note "Homebrew not installed, skipped"
fi

# ── 9 · Docker ───────────────────────────────────────────────────────────────
step "Docker"
if have docker && docker info >/dev/null 2>&1; then
  docker system df 2>/dev/null | while IFS= read -r l; do info "$l"; done
  note "Volumes, containers and tagged images are NEVER touched (volumes hold your databases)."
  cat_begin docker "Docker leftovers" safe cube \
    "Untagged images and unused build cache. Volumes (your databases), containers and tagged images are never touched."
  emit_cat -1 y
  if confirm "Remove dangling (untagged) images and unused build cache?" y; then
    run_cmd docker image prune -f
    run_cmd docker builder prune -f
    emit CATDONE "$CAT_ID" 0
  fi
else
  note "Docker not running, skipped"
fi

# ── 10 · Stale project dependencies ──────────────────────────────────────────
step "Old project dependencies"
cat_begin projdeps "Old project dependencies" reinstall folder \
  "node_modules, PHP vendor and Maven target folders of projects you have not touched in ${DEP_DAYS}+ days. One install command brings them back."
note "Only folders with a manifest AND a lockfile beside them, in projects idle for ${DEP_DAYS}+ days."
ROOTS=()
for r in Projects Developer Code dev src workspace Sites git repos IdeaProjects PhpstormProjects PycharmProjects WebstormProjects; do
  [[ -d "$HOME/$r" ]] && ROOTS+=("$HOME/$r")
done
if [[ -f "$HOME/.config/wisp/roots.txt" ]]; then   # extra project folders you choose
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ "$line" == "~"* ]] && line="$HOME${line#\~}"
    [[ -n "$line" && -d "$line" && "$line" == "$HOME"/* ]] && ROOTS+=("$line")
  done <"$HOME/.config/wisp/roots.txt"
fi
if (( ${#ROOTS[@]} > 0 )); then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    dep_ok "$d" || continue
    project_stale "${d%/*}" "$DEP_DAYS" || continue
    add "$d"
  done < <(find "${ROOTS[@]}" -maxdepth 7 \( -name .git -o -name .Trash \) -prune -o \
             -type d \( -name node_modules -o -name vendor -o -name target \) -print -prune 2>/dev/null)
fi
offer "Delete these old dependency folders? (reinstall with npm/yarn/composer/mvn)" n

# ── 11 · Old installers → Trash (recoverable), terminal only ────────────────
if ! $APP_MODE; then
  step "Old installers in ~/Downloads  (.dmg / .pkg older than 30 days)"
  cat_begin installers "Old installers" review tray.full "Moved to the Trash, not deleted."
  INSTALLERS=(); inst_kb=0
  if $ASSUME_YES; then
    note "skipped in --yes mode (moving your downloads always needs a human yes)"
  elif [[ -d "$HOME/Downloads" ]]; then
    while IFS= read -r -d '' f; do
      INSTALLERS+=("$f"); k=$(size_kb "$f"); inst_kb=$(( inst_kb + k ))
      info "$(printf '%10s' "$(human "$k")")  $(pretty "$f")"
    done < <(find "$HOME/Downloads" -maxdepth 1 -type f \( -iname '*.dmg' -o -iname '*.pkg' \) -mtime +30 -print0 2>/dev/null)
    if (( ${#INSTALLERS[@]} > 0 )); then
      info "${BOLD}$(printf '%10s' "$(human "$inst_kb")")  total${RESET}"
      if confirm "Move these to the Trash? (not deleted, you can Put Back)" n; then
        for (( i=0; i<${#INSTALLERS[@]}; i++ )); do
          run_cmd osascript -e 'on run argv' \
            -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' \
            -e 'end run' "${INSTALLERS[i]}"
        done
      fi
    else
      note "none found"
    fi
  fi
fi

# ── 12 · Trash ───────────────────────────────────────────────────────────────
step "Trash"
cat_begin trash "Empty the Trash" permanent trash \
  "Permanent: items in the Trash cannot be recovered afterwards. Off by default."
if trash_items=$(ls -A "$HOME/.Trash" 2>/dev/null); then
  if [[ -z "$trash_items" ]]; then
    note "Trash is empty"
  else
    tkb=$(size_kb "$HOME/.Trash")
    info "$(printf '%10s' "$(human "$tkb")")  $(printf '%s\n' "$trash_items" | wc -l | tr -d ' ') items in Trash"
    emit_cat "$tkb" n
    if confirm "Empty the Trash? (permanent, default is No)" n; then
      run_cmd osascript -e 'tell application "Finder" to empty trash'; emit CATDONE "$CAT_ID" "$tkb"
    fi
  fi
else
  note "Cannot measure the Trash (this terminal lacks Full Disk Access)."
  emit_cat -1 n
  if confirm "Ask Finder to empty the Trash anyway? (permanent, default is No)" n; then
    run_cmd osascript -e 'tell application "Finder" to empty trash'; emit CATDONE "$CAT_ID" 0
  fi
fi

# ── Optional maintenance ─────────────────────────────────────────────────────
if $MAINT; then
  section "Maintenance (frees no space)"
  cat_begin maint "Maintenance" review wrench "DNS flush / Spotlight re-index."
  if confirm "Flush the DNS cache? (sudo)" n; then
    run_cmd sudo dscacheutil -flushcache
    run_cmd sudo killall -HUP mDNSResponder
  fi
  if confirm "Rebuild the Spotlight index? (sudo; search is slow for a while)" n; then
    run_cmd sudo mdutil -E /
  fi
fi

# =============================================================================
#  REPORT ONLY: big things this script will never delete for you
# =============================================================================
if ! $NO_REPORT; then
  section "Worth a look (report only, nothing here is deleted)"
  report_items
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple' || true)
  if [[ "${snaps:-0}" =~ ^[0-9]+$ ]] && (( snaps > 0 )); then
    info "$snaps Time Machine local snapshot(s). macOS frees these automatically when space runs low."
  fi
  big="$(big_files | awk -F'\t' '$2=="user"' | head -n 10)"
  if [[ -n "$big" ]]; then
    log ""; info "${BOLD}Largest files in your home folder (> 250 MB):${RESET}"
    printf '%s\n' "$big" | while IFS=$'\t' read -r kb k f; do
      info "$(printf '%10s' "$(human "$kb")")  $(pretty "$f")"
    done
  fi
fi

# =============================================================================
#  SUMMARY
# =============================================================================
section "Summary"
if $DRY_RUN; then
  info "Dry run: up to ${BOLD}$(human "$FREED_KB")${RESET} could be reclaimed if you said yes to everything"
  note "(plus whatever brew / docker / simctl / pnpm clean up; those are not measured here)."
  info "Run again without --dry-run to clean."
  emit RESULT dry "$FREED_KB" "$FREE_BEFORE" "$FREE_BEFORE"
else
  sync 2>/dev/null || true
  FREE_AFTER=$(free_kb)
  info "Files removed by this script : ${BOLD}$(human "$FREED_KB")${RESET}"
  info "Free disk space              : $(human "$FREE_BEFORE") → ${BOLD}$(human "$FREE_AFTER")${RESET}"
  note "macOS can take a minute to show freed space (APFS snapshots / purgeable space)."
  emit RESULT "done" "$FREED_KB" "$FREE_BEFORE" "$FREE_AFTER"
fi
note "log saved to $(pretty "$LOG_FILE")"
log ""
