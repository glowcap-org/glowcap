#!/usr/bin/env bash
# Fetch and safely extract the pinned official Mbed TLS release source.
#
# dep Mbed TLS: TLS for the relay transport's `wss://` connections from Zig and
#   its C archive, built from the official release source.

set -euo pipefail

readonly VERSION=4.2.0
readonly ARCHIVE="mbedtls-${VERSION}.tar.bz2"
readonly ROOT="mbedtls-${VERSION}"
readonly URL="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${VERSION}/${ARCHIVE}"
readonly SHA256=2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea
readonly MAX_BYTES=33554432

if [[ $# -ne 1 ]]; then
	printf '%s\n' "usage: fetch-mbedtls.sh OUTPUT_DIRECTORY" >&2
	exit 2
fi
readonly OUTPUT=$1

for program in curl tar; do
	if ! command -v "$program" >/dev/null 2>&1; then
		printf 'fetch-mbedtls: required program is missing: %s\n' "$program" >&2
		exit 1
	fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/glowcap-mbedtls.XXXXXX")
readonly scratch
trap 'rm -rf -- "$scratch"' EXIT
readonly tarball_path="$scratch/$ARCHIVE"

curl -fsSL --proto '=https' --tlsv1.2 --max-filesize "$MAX_BYTES" \
	-A 'glowcap-build/mbedtls-fetch' -o "$tarball_path" "$URL"
actual_bytes=$(wc -c <"$tarball_path")
if ((actual_bytes > MAX_BYTES)); then
	printf 'fetch-mbedtls: archive exceeds %d-byte ceiling: %d\n' \
		"$MAX_BYTES" "$actual_bytes" >&2
	exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tarball_path")
	actual=${actual%% *}
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$tarball_path")
	actual=${actual%% *}
else
	printf '%s\n' "fetch-mbedtls: sha256sum or shasum is required" >&2
	exit 1
fi
if [[ "$actual" != "$SHA256" ]]; then
	printf 'fetch-mbedtls: checksum mismatch: expected %s, got %s\n' "$SHA256" "$actual" >&2
	exit 1
fi

# Reuse the release-archive listing parser, but inspect only the source trees
# this build extracts. The official archive contains unrelated example
# symlinks; none may enter the compiled subset.
# shellcheck source=../c-abi/archive-hygiene.sh
source "$(dirname "$0")/../c-abi/archive-hygiene.sh"
readonly prefixes=(
	"$ROOT/include"
	"$ROOT/library"
	"$ROOT/tf-psa-crypto/include"
	"$ROOT/tf-psa-crypto/core"
	"$ROOT/tf-psa-crypto/dispatch"
	"$ROOT/tf-psa-crypto/extras"
	"$ROOT/tf-psa-crypto/platform"
	"$ROOT/tf-psa-crypto/utilities"
	"$ROOT/tf-psa-crypto/drivers/builtin"
	"$ROOT/tf-psa-crypto/drivers/everest"
	"$ROOT/tf-psa-crypto/drivers/p256-m"
)
for prefix in "${prefixes[@]}"; do
	if ! violation=$(archive_hygiene_check_compressed "$tarball_path" "$prefix" j); then
		printf 'fetch-mbedtls: unsafe official archive member under %s: %s\n' \
			"$prefix" "${violation:-listing failed}" >&2
		exit 1
	fi
done

mkdir -p -- "$OUTPUT"
TAR_OPTIONS= tar --no-same-owner --no-same-permissions -xjf "$tarball_path" \
	-C "$OUTPUT" --strip-components=1 \
	"$ROOT/LICENSE" \
	"${prefixes[@]}"

printf 'mbedtls %s %s\n' "$VERSION" "$SHA256" >"$OUTPUT/GLOWCAP-PIN"
