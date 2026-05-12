#!/bin/sh
# kill-overlayfs.sh - stop the overlayfs init session recorded in guix-gd-overlayfs.pid
#
# Reads PID from a PID file (default: ${GUIX_GD_DEV_ROOT:-/tmp/guix-gd-overlayfs-${USER:-user}}/overlayfs-container.pid),
# lists all processes in the same process group (PGID),
# and prompts to send SIGTERM or SIGKILL to the entire process group.
#
# POSIX-sh compatible. Uses `ps`, `awk`, `kill`, `tr`, `printf`, `read`.

set -eu
# Try to enable pipefail if the shell supports it (not strictly POSIX).
set -o pipefail 2>/dev/null || true

# PID file (1st arg) or default location under GUIX_GD_DEV_ROOT
PID_FILE="${1:-${GUIX_GD_DEV_ROOT:-/tmp/guix-gd-overlayfs-${USER:-user}}/overlayfs-container.pid}"

# Ensure PID file exists and is readable
if [ ! -r "$PID_FILE" ]; then
  printf 'PID file not found or unreadable: %s\n' "$PID_FILE" >&2
  exit 1
fi

# Read the first non-empty token from the PID file and strip whitespace
read -r PID < "$PID_FILE" || PID=''
PID="$(printf '%s' "$PID" | tr -d '[:space:]')"

# Validate PID is a non-empty decimal number
if [ -z "$PID" ]; then
  printf 'PID file is empty: %s\n' "$PID_FILE" >&2
  exit 1
fi
case "$PID" in
  *[!0-9]*)
    printf 'Invalid PID in %s: %s\n' "$PID_FILE" "$PID" >&2
    exit 1
    ;;
esac

# Check whether the leader process is running
if ! kill -0 "$PID" 2>/dev/null; then
  printf 'No running process with PID %s\n' "$PID"
  printf 'Remove stale PID file %s? [y/N]: ' "$PID_FILE"
  read -r reply
  case "$reply" in
    [yY]*) rm -f "$PID_FILE" && printf 'Removed %s\n' "$PID_FILE"; exit 0 ;; 
    *) printf 'Aborting.\n'; exit 1 ;;
  esac
fi

# Determine the process group ID (PGID) of the leader
PGID="$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$PGID" ]; then
  printf 'Unable to determine PGID for PID %s\n' "$PID" >&2
  exit 1
fi

# Summary and listing of group members
printf 'Found leader PID: %s\nPGID: %s\n\n' "$PID" "$PGID"
printf '%-7s %-7s %-7s %-6s %s\n' 'PID' 'PPID' 'PGID' 'STAT' 'COMMAND'
# Print all processes whose PGID matches
ps -eo pid,ppid,pgid,stat,args --no-headers | awk -v pgid="$PGID" '$3==pgid{print}'

# Prompt for action: terminate (SIGTERM) or kill (SIGKILL)
printf '\nSend signal to entire process group %s? [(t)erm/(k)ill/(c)ancel]: ' "$PGID"
read -r CHOICE

case "$CHOICE" in
  t|T)
    printf 'Sending SIGTERM to process group %s\n' "$PGID"
    # Use `-s SIGNAL` form and `--` before negative PID to avoid it being parsed as option
    if kill -s TERM -- -"$PGID" 2>/dev/null; then :; else
      printf 'Failed to signal group; trying leader PID %s\n' "$PID" >&2
      kill -s TERM "$PID" 2>/dev/null || { printf 'Failed to send SIGTERM (permission?).\n' >&2; exit 1; }
    fi
    ;;
  k|K)
    printf 'Sending SIGKILL to process group %s\n' "$PGID"
    if kill -s KILL -- -"$PGID" 2>/dev/null; then :; else
      printf 'Failed to signal group; trying leader PID %s\n' "$PID" >&2
      kill -s KILL "$PID" 2>/dev/null || { printf 'Failed to send SIGKILL (permission?).\n' >&2; exit 1; }
    fi
    ;;
  *)
    printf 'Cancelled.\n'
    exit 1
    ;;
esac

# Wait a short time for the group to exit
wait_secs=5
i=0
while [ "$i" -lt "$wait_secs" ]; do
  any="$(ps -eo pid,pgid --no-headers | awk -v pgid="$PGID" '$2==pgid{print $1; exit}')" || true
  [ -z "$any" ] && break
  sleep 1
  i=$((i + 1))
done

if [ -z "$any" ]; then
  printf 'Process group %s appears terminated.\n' "$PGID"
  # If leader is gone remove the PID file
  if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PID_FILE" && printf 'Removed PID file %s\n' "$PID_FILE"
  fi
  exit 0
else
  printf 'Process group still running (example PID: %s).\n' "$any"
  printf 'Remove PID file anyway? [y/N]: '
  read -r reply
  case "$reply" in
    [yY]*) rm -f "$PID_FILE" && printf 'Removed %s\n' "$PID_FILE"; exit 0 ;; 
    *) printf 'Left PID file intact: %s\n' "$PID_FILE"; exit 1 ;;
  esac
fi
