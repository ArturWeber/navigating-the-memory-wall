#!/usr/bin/env bash
set -euo pipefail

PIDFILE="sweep.pid"
test -f "$PIDFILE" || { echo "No $PIDFILE found."; exit 1; }

PID="$(cat "$PIDFILE")"

# Kill the whole *process group* of PID by using negative PID.
# Step 1: ask nicely
echo "Sending TERM to process group -$PID"
kill -TERM -- "-$PID" 2>/dev/null || true
sleep 5

# Step 2: if still alive, interrupt (sometimes better for Make/DC)
if kill -0 "$PID" 2>/dev/null; then
  echo "Still alive. Sending INT to process group -$PID"
  kill -INT -- "-$PID" 2>/dev/null || true
  sleep 5
fi

# Step 3: last resort
if kill -0 "$PID" 2>/dev/null; thenpstree -pu $USER | grep common_shell_ex¡
  echo "Still alive. Sending KILL to process group -$PID"
  kill -KILL -- "-$PID" 2>/dev/null || true
fi

echo "Done."