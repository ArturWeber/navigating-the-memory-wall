#!/usr/bin/env bash
set -euo pipefail

LOG="sweep_execution_$(date +%Y%m%d_%H%M%S).log"
PIDFILE="sweep.pid"

# Start in a new session. The PID we capture becomes the *session leader*.
# Redirect stdin from /dev/null so it never tries to read from your terminal.
setsid -w bash -lc '
  set -euo pipefail
  echo "Started at: $(date)"
  echo "Host: $(hostname)"
  echo "PID: $$"
  ./run_sweep.sh
' >"$LOG" 2>&1 < /dev/null &

PID=$!
echo "$PID" > "$PIDFILE"

echo "Launched sweep."
echo "  PID (session leader) : $PID"
echo "  PID file             : $PIDFILE"
echo "  Log                  : $LOG"
echo
echo "To watch: tail -f $LOG"
echo "To stop : ./run_sweep_stop.sh"