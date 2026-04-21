#!/usr/bin/env bash

# ANSI color codes
_COLOR_RESET='\033[0m'
_COLOR_CYAN='\033[0;36m'
_COLOR_GREEN='\033[0;32m'
_COLOR_YELLOW='\033[1;33m'
_COLOR_RED='\033[0;31m'

log() {
  echo "[windrose] $*"
}

log_info() {
  echo -e "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $*"
}

log_ok() {
  echo -e "${_COLOR_GREEN}[windrose]${_COLOR_RESET} $*"
}

log_warn() {
  echo -e "${_COLOR_YELLOW}[windrose]${_COLOR_RESET} $*"
}

log_error() {
  echo -e "${_COLOR_RED}[windrose]${_COLOR_RESET} $*"
}

quote() {
  printf '%q' "$1"
}

print_log_file() {
  local label="$1"
  local file="$2"

  if [[ -f "$file" ]]; then
    log "$label"
    tail -n 120 "$file" || true
  fi
}

print_prefixed_lines() {
  local prefix="$1"

  while IFS= read -r line; do
    log "$prefix$line"
  done
}

check_free_space() {
  local path="$1"
  local min_mb="$2"
  local avail_kb avail_mb

  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  avail_mb=$((avail_kb / 1024))

  if (( avail_mb < min_mb )); then
    log "ERROR: low disk space at $path (${avail_mb} MB free). Free at least ${min_mb} MB and start the container again."
    exit 70
  fi
}

ensure_user_mapping() {
  groupmod -o -g "$PGID" steam 2>/dev/null || true
  usermod -o -u "$PUID" steam 2>/dev/null || true

  mkdir -p \
    "$SERVERDIR" \
    "$STEAM_HOME" \
    "$STEAM_HOME/.local/share" \
    "$STEAM_HOME/.config" \
    "$STEAM_HOME/.cache" \
    "$STEAM_HOME/Steam"

  if [ ! -L "$STEAM_HOME/.steam" ]; then
    ln -sf "$STEAM_HOME/Steam" "$STEAM_HOME/.steam" 2>/dev/null || true
  fi

  chown -R steam:steam /opt/steamcmd "$STEAM_HOME" "$SERVERDIR" 2>/dev/null || true
}

dump_wine_diagnostics() {
  local arch_marker="missing"

  if [[ -f "$WINEPREFIX/system.reg" ]]; then
    arch_marker="$(grep -m1 '^#arch=' "$WINEPREFIX/system.reg" 2>/dev/null || true)"
  fi

  log "Wine diagnostics"
  log "  WINEPREFIX=$WINEPREFIX"
  log "  WINEARCH=${WINEARCH:-unset}"
  log "  WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-unset}"
  log "  prefix arch marker=${arch_marker:-missing}"

  if command -v wine >/dev/null 2>&1; then
    log "  wine version=$(wine --version 2>/dev/null || echo unavailable)"
  fi

  if [[ -e "$WINEPREFIX/drive_c/windows/system32/kernel32.dll" ]]; then
    log "  kernel32.dll present=yes"
  else
    log "  kernel32.dll present=no"
  fi

  if [[ -d "$WINEPREFIX" ]]; then
    find "$WINEPREFIX" -mindepth 1 -maxdepth 1 \
      -printf '%M %n %u %g %10s %TY-%Tm-%Td %TH:%TM %f\n' | head -n 10 | print_prefixed_lines "  "
  fi
}