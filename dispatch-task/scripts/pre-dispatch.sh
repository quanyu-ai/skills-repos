#!/bin/bash
# No fixed tracker/word-count/keyword gate. Reuse the existing input sanity check.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-task-desc.sh" "$@"
