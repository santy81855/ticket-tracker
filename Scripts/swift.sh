#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command="${1:?Pass build, test, or package}"
shift
case "$command" in
  build|test|package) ;;
  *) printf 'Unsupported SwiftPM command: %s\n' "$command" >&2; exit 1 ;;
esac
count="${GIT_CONFIG_COUNT:-0}"
case "$count" in
  *[!0-9]*) printf 'Invalid GIT_CONFIG_COUNT\n' >&2; exit 1 ;;
esac
# Approved, process-local compatibility setting for SwiftPM's bare package caches.
exec env GIT_CONFIG_COUNT="$((count + 1))" \
  "GIT_CONFIG_KEY_${count}=safe.bareRepository" "GIT_CONFIG_VALUE_${count}=all" \
  xcrun swift "$command" --scratch-path "$HOME/Library/Caches/TicketTracker/Build" "$@"
