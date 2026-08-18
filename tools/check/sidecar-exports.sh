#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
	printf 'usage: sidecar-exports.sh LIBRARY PUBLIC_PREFIX PRIVATE_PREFIX\n' >&2
	exit 2
fi

library=$1
public_prefix=$2
private_prefix=$3

if ! command -v nm >/dev/null 2>&1; then
	printf 'sidecar-exports: nm is required\n' >&2
	exit 1
fi

symbols=$(mktemp "${TMPDIR:-/tmp}/pancake-sidecar-exports.XXXXXX")
trap 'rm -f "$symbols"' EXIT

nm -D --defined-only "$library" | awk 'NF >= 3 { print $NF }' >"$symbols"

if [ ! -s "$symbols" ]; then
	printf 'sidecar-exports: %s exports no public symbols\n' "$library" >&2
	exit 1
fi

while IFS= read -r symbol; do
	case "$symbol" in
		"${private_prefix}"*)
			printf 'sidecar-exports: %s leaks private symbol %s\n' "$library" "$symbol" >&2
			exit 1
			;;
		"${public_prefix}"*) ;;
		*)
			printf 'sidecar-exports: %s leaks symbol outside %s: %s\n' \
				"$library" "$public_prefix" "$symbol" >&2
			exit 1
			;;
	esac
done <"$symbols"
