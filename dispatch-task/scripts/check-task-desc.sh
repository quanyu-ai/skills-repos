#!/bin/bash
# Input sanity only; authorization and user-result judgment belong to the actual task.
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "usage: $0 <task-file|->" >&2; exit 2; fi
if [ "$1" = "-" ]; then content=$(cat); else
  [ -f "$1" ] || { echo "Task input is not a readable file" >&2; exit 2; }
  content=$(cat -- "$1")
fi
[ -n "${content//[[:space:]]/}" ] || { echo "Task input is empty" >&2; exit 2; }
printf '%s\n' 'Task input is present; no format score, tracker or delivery claim.'
