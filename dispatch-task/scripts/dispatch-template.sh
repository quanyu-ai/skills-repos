#!/bin/bash
# Optional task prompt; not a dispatch or acceptance gate.
set -euo pipefail
case "${1:-help}" in
 dev|deploy|test|proto|infra)
  cat "$(dirname "$0")/../templates/task-template.md"
  ;;
 *) echo 'Usage: dispatch-template.sh {dev|deploy|test|proto|infra}';;
esac
