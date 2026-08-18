#!/usr/bin/env bash
# Verify that the optional secure relay's shared archive exposes only its C ABI.

set -euo pipefail

if [[ $# -ne 1 ]]; then
	printf '%s\n' "usage: relay-archive-symbols.sh SHARED_LIBRARY" >&2
	exit 2
fi

readonly library=$1
if [[ ! -f "$library" ]]; then
	printf 'relay-archive-symbols: library not found: %s\n' "$library" >&2
	exit 1
fi
if ! command -v nm >/dev/null 2>&1; then
	printf '%s\n' "relay-archive-symbols: nm is required" >&2
	exit 1
fi

if [[ $(uname -s) == Darwin ]]; then
	symbols=$(nm -gU "$library" | awk '{print $NF}')
else
	symbols=$(nm -D --defined-only "$library" | awk '{print $NF}' | sed 's/@.*$//')
fi

if ! grep -qx 'pancake_relay_archive_fingerprint' <<<"$symbols"; then
	printf '%s\n' "relay-archive-symbols: relay fingerprint is not exported" >&2
	exit 1
fi
unexpected=$(grep -Ev '^(pancake_relay_[A-Za-z0-9_]+)?$' <<<"$symbols" || true)
if [[ -n "$unexpected" ]]; then
	printf '%s\n' "relay-archive-symbols: unexpected shared exports:" >&2
	printf '%s\n' "$unexpected" >&2
	exit 1
fi
