#!/usr/bin/env bash
# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
#
# zhelpers.sh — shared library sourced by every z-script (bash port). Not run directly.

# ---- config location --------------------------------------------------------
_ZDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# zconfig.json lives next to the scripts; override with $ZCONFIG.
ZCONFIG="${ZCONFIG:-$_ZDIR/zconfig.json}"

# ---- colours (only when stdout is a TTY) ------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m';   C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m';  C_GRAY=$'\033[90m'; C_MAGENTA=$'\033[35m'
else
  C_RESET= C_CYAN= C_GREEN= C_YELLOW= C_RED= C_GRAY= C_MAGENTA=
fi
info() { printf '%s%s%s\n' "$C_CYAN"    "$*" "$C_RESET"; }
ok()   { printf '%s%s%s\n' "$C_GREEN"   "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW"  "$*" "$C_RESET"; }
err()  { printf '%s%s%s\n' "$C_RED"     "$*" "$C_RESET" >&2; }
dim()  { printf '%s%s%s\n' "$C_GRAY"    "$*" "$C_RESET"; }
note() { printf '%s%s%s\n' "$C_MAGENTA" "$*" "$C_RESET"; }

# ---- dependency guard -------------------------------------------------------
z_require() {
  local miss=0 t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { err "Missing required tool: $t"; miss=1; }
  done
  [ "$miss" -eq 0 ] || exit 1
}

# ---- config accessors (jq) --------------------------------------------------
z_need_config() {
  z_require jq
  if [ ! -f "$ZCONFIG" ]; then
    err "zconfig.json not found at $ZCONFIG"
    dim "     Copy zconfig.example.json to zconfig.json and fill in your values."
    exit 1
  fi
}
zq()         { jq -r "$1" "$ZCONFIG"; }
# All project keys, config order, skipping _comment-style keys.
zproj_keys() { zq '.projects | keys_unsorted[] | select(startswith("_") | not)'; }
zproj_csv()  { zproj_keys | paste -sd',' -; }
# Keys of projects that have a "domain" (deployed / publicly reachable).
zproj_keys_with_domain() {
  jq -r '.projects | to_entries[] | select((.key | startswith("_") | not) and .value.domain != null) | .key' "$ZCONFIG"
}
# Field of a project:  zproj <key> <dotpath>   e.g.  zproj sp .kind   |   zproj sp .ports.dev
zproj()      { jq -r --arg k "$1" ".projects[\$k]$2 // empty" "$ZCONFIG"; }
zproj_require() {
  if [ "$(jq -r --arg k "$1" '(.projects[$k] != null)' "$ZCONFIG")" != "true" ]; then
    err "Unknown project key '$1'. Available: $(zproj_csv)"
    exit 1
  fi
}
zec2_ip()     { zq '.ec2.ip'; }
zec2_user()   { zq '.ec2.user'; }
zec2_pem()    { zq '.ec2.pemKey'; }
zec2_target() { printf '%s@%s' "$(zec2_user)" "$(zec2_ip)"; }
# Remote compose directory: remote.composeDir if set, else remote.path.
zremote_compose_dir() {
  local d
  d="$(zproj "$1" .remote.composeDir)"
  [ -n "$d" ] || d="$(zproj "$1" .remote.path)"
  printf '%s' "$d"
}
# First project of kind 'edge' (or empty).
zedge_key() {
  jq -r '.projects | to_entries[] | select((.key | startswith("_") | not) and .value.kind == "edge") | .key' "$ZCONFIG" | head -1
}

# ---- SSH helpers ------------------------------------------------------------
# Run a bash command on the server. zssh is bare; zec2_step adds a label and
# exits non-zero loudly (mirrors Invoke-Ec2Step).
zssh() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$(zec2_pem)" "$(zec2_target)" "$@"
}
zec2_step() {
  local label="$1"; shift
  dim "  >> $label"
  zssh "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "Remote step failed: '$label' (exit $rc)."
    return $rc
  fi
}

# ---- HTTP / TCP helpers -----------------------------------------------------
# HTTP status code for a URL with optional Host header ("000" on connect fail).
http_code() {
  local url="$1" host_header="${2:-}" args=(-s -o /dev/null -w '%{http_code}' -L --max-time 15)
  [ -n "$host_header" ] && args+=(-H "Host: $host_header")
  curl "${args[@]}" "$url" 2>/dev/null || printf '000'
}
# GET a URL body (with Host header); empty on failure.
http_get() {
  local url="$1" host_header="${2:-}" args=(-s --max-time 10)
  [ -n "$host_header" ] && args+=(-H "Host: $host_header")
  curl "${args[@]}" "$url" 2>/dev/null
}
# TCP connect check via bash /dev/tcp (uses `timeout` when available).
tcp_check() {
  local host="$1" port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  else
    bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  fi
}

# ---- build-version helpers --------------------------------------------------
# "v<productVersion>.<buildNumber>" from a build-version.json file, or "unknown".
json_build_label() {
  local f="$1"
  [ -f "$f" ] || { printf 'unknown'; return; }
  jq -r '"v\(.productVersion).\(.buildNumber)"' "$f" 2>/dev/null || printf 'unknown'
}
# Local build label by project kind (mirrors Get-LocalVersionLabel).
local_version_label() {
  local key="$1" kind root out
  kind="$(zproj "$key" .kind)"; root="$(zproj "$key" .localRoot)"
  case "$kind" in
    python)
      if [ -f "$root/scripts/build_version_tool.py" ]; then
        out="$(cd "$root" && { python3 scripts/build_version_tool.py get 2>/dev/null || python scripts/build_version_tool.py get 2>/dev/null; } | tail -1)"
        [ -n "$out" ] && { printf '%s' "$out"; return; }
      fi
      [ -f "$root/.build_version" ] && { tail -1 "$root/.build_version" | tr -d '[:space:]'; return; }
      printf 'unknown' ;;
    vite)   json_build_label "$root/build-version.json" ;;
    nextjs) json_build_label "$root/public/build-version.json" ;;
    *)      printf 'unknown' ;;
  esac
}
# Live/server build label by kind (HTTP endpoints; python falls back to SSH).
remote_version_label() {
  local key="$1" host="$2" kind domain body label
  kind="$(zproj "$key" .kind)"; domain="$(zproj "$key" .domain)"
  if [ "$kind" = "vite" ]; then
    body="$(http_get "http://$host/build-version.json" "$domain")"
    label="$(printf '%s' "$body" | jq -r '"v\(.productVersion).\(.buildNumber)"' 2>/dev/null)"
    [ -n "$label" ] && [ "$label" != "null" ] && { printf '%s' "$label"; return; }
  else
    body="$(http_get "http://$host/api/build-version" "$domain")"
    label="$(printf '%s' "$body" | jq -r '.build_version // empty' 2>/dev/null)"
    [ -n "$label" ] && { printf '%s' "$label"; return; }
    if [ "$kind" = "python" ] && [ -f "$(zec2_pem)" ]; then
      label="$(zssh "cat $(zproj "$key" .remote.path)/.build_version 2>/dev/null || true" 2>/dev/null | tail -1 | tr -d '[:space:]')"
      [ -n "$label" ] && { printf '%s' "$label"; return; }
    fi
  fi
  printf 'unknown'
}

# ---- MOTD -------------------------------------------------------------------
# Print a random banner from <root>/motd/*.txt (the PowerShell version keeps a
# shuffled rotation state; the bash port picks at random — same spirit, simpler).
show_project_motd() {
  local root="$1" files=()
  [ -d "$root/motd" ] || return 0
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$root/motd" -maxdepth 1 -name '*.txt' -type f -print0 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 0
  printf '\n'; cat "${files[RANDOM % ${#files[@]}]}"; printf '\n'
}

# ---- archive builder --------------------------------------------------------
# Junk filtered out of every deploy/backup zip (mirrors the PowerShell lists).
_Z_JUNK_DIRS=(.git .svn .hg __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox
  node_modules .npm .yarn .pnpm-store .next .nuxt .svelte-kit .turbo .parcel-cache
  .cache .idea .vscode coverage htmlcov .nyc_output)
_Z_JUNK_EXTS=(swp swo swn tmp orig rej bak backup old pyc pyo pyd tsbuildinfo log
  db sqlite sqlite3 zip dmg arj gz tgz tar rar 7z iso bz2 xz lz lzma cab jar war ear z zst zstd)
_Z_SCRIPT_EXTS=(ps1 cmd bat)
_Z_JUNK_NAMES=(.DS_Store Thumbs.db desktop.ini)

# Top-level exclude names for a project's archive (mirrors Get-ArchiveExcludes).
# Usage: z_archive_excludes <key> [for_backup:0|1]   -> one name per line
z_archive_excludes() {
  local key="$1" for_backup="${2:-0}" kind
  kind="$(zproj "$key" .kind)"
  printf '%s\n' .git .idea .vscode .claude tmp nul .DS_Store backups
  case "$kind" in
    python)
      printf '%s\n' .venv venv __pycache__ .pytest_cache .nicegui archive dist build htmlcov
      [ "$for_backup" -eq 1 ] || printf '%s\n' uploads ;;  # deploys exclude user uploads; backups keep them
    vite)   printf '%s\n' node_modules dist ;;
    nextjs) printf '%s\n' node_modules .next .env .env.local .env.production .vercel coverage out build next-env.d.ts ;;
  esac
  jq -r --arg k "$key" '.projects[$k].deploy.exclude // [] | .[]' "$ZCONFIG"
}

# Build a zip from a source directory.
# Usage: z_archive <src_dir> <dest_zip> <include_scripts:0|1> <extra_file|-> [top_excludes...]
z_archive() {
  local src="$1" dest="$2" include_scripts="$3" extra="$4"; shift 4
  z_require zip
  [ -d "$src" ] || { err "Source path is not a directory: $src"; return 1; }
  rm -f "$dest"; mkdir -p "$(dirname "$dest")"

  local pat=() e n
  for n in "$@";                do [ -n "$n" ] && pat+=("$n" "$n/*"); done
  for n in "${_Z_JUNK_DIRS[@]}"; do pat+=("$n/*" "*/$n/*"); done
  for e in "${_Z_JUNK_EXTS[@]}"; do pat+=("*.${e}"); done
  if [ "$include_scripts" -ne 1 ]; then
    for e in "${_Z_SCRIPT_EXTS[@]}"; do pat+=("*.${e}"); done
  fi
  for n in "${_Z_JUNK_NAMES[@]}"; do pat+=("$n" "*/$n"); done

  ( cd "$src" && zip -rq "$dest" . -x "${pat[@]}" ) || { err "zip failed for $src"; return 1; }
  if [ -n "$extra" ] && [ "$extra" != "-" ] && [ -f "$extra" ]; then
    zip -jq "$dest" "$extra" || warn "  could not add extra file: $extra"
  fi
  dim "  Archive: $dest ($(z_size_mb "$dest") MB)"
}

# File size in MB (portable: bytes via wc).
z_size_mb() { awk -v b="$(wc -c < "$1" 2>/dev/null || echo 0)" 'BEGIN{printf "%.2f", b/1048576}'; }

# Percent-decode a URL component (for DATABASE_URL passwords).
z_urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }

# ---- port operations (Linux/macOS: needs lsof) ------------------------------
# Kill processes LISTENING on a TCP port. Progress -> stderr; killed count -> stdout.
kill_listeners() {
  local port="$1" pids pid n=0
  pids="$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null | sort -u)"
  for pid in $pids; do
    dim "  Killing PID $pid (port $port)" >&2
    if kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}
