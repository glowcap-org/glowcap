#!/bin/sh
# Operator/CI helper: fetch a pancake C-ABI release tarball into the
# abi-versioned cache.
#
# Bindings do NOT call this script (ADR-0077). Each language package ships
# `c-abi-resolve.json` and downloads with language-native code so a published
# crate/wheel/npm package works without a Zig checkout. This script is for
# humans and CI that want the same cache layout from a shell.
#
# Contract: bindings/c-abi-resolve.json
#
# Usage:
#   tools/c-abi/fetch-c-abi.sh
#   tools/c-abi/fetch-c-abi.sh --version 0.1.0 --target x86_64-linux
#
# Environment:
#   PANCAKE_REPO_ROOT          repository root (default: parent of tools/)
#   PANCAKE_CACHE_DIR          cache base (default: ~/.cache/pancake/c-abi,
#                              else $TMPDIR/<fallback_cache_name from contract>)
#   PANCAKE_RELEASE_BASE_URL   override release download base URL
#   PANCAKE_DOWNLOAD=1         attempt fetch even when releases_published is false
#   PANCAKE_SKIP_DOWNLOAD=1    exit 0 without fetching
#   PANCAKE_STRICT=1           exit non-zero on soft-fail paths (network/tooling)
#   PANCAKE_ALLOW_INSECURE=1   allow a non-HTTPS release base URL
#
# Exit: 0 on success or soft-fail (network/tooling/unpublished); non-zero on
# hard hygiene failure (HTTPS/checksum/extract), or when PANCAKE_STRICT=1 and
# a soft path fails. When the contract's releases_published is false, exit 0
# without curling unless PANCAKE_DOWNLOAD=1.

set -eu

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

truthy() {
	case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" in
	1 | true | yes) return 0 ;;
	*) return 1 ;;
	esac
}

die_usage() {
	echo "pancake fetch-c-abi: $1" >&2
	exit 2
}

soft_fail() {
	msg=$1
	if truthy "${PANCAKE_STRICT:-}"; then
		echo "pancake fetch-c-abi: $msg" >&2
		exit 1
	fi
	echo "pancake fetch-c-abi: $msg (soft-fail)" >&2
	exit 0
}

# Hygiene/security failures always fail closed (never gated on STRICT).
hard_fail() {
	echo "pancake fetch-c-abi: $1" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || soft_fail "$1 not on PATH"
}

# Read a string field from the resolve contract.
contract() {
	jq -r ".$1" "$CONTRACT"
}

# Substitute {version}, {target}, and optional {cache_base} in a contract template.
apply_contract_template() {
	printf '%s' "$1" | sed \
		-e "s|{cache_base}|${CACHE_BASE}|g" \
		-e "s|{version}|${VERSION}|g" \
		-e "s|{target}|${TARGET}|g"
}

abi_version_from_header() {
	header="$REPO_ROOT/$(contract version_header)"
	if [ ! -f "$header" ]; then
		contract abi_version
		return
	fi
	major=$(sed -n 's/^#define PANCAKE_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header" | head -1)
	minor=$(sed -n 's/^#define PANCAKE_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header" | head -1)
	patch=$(sed -n 's/^#define PANCAKE_VERSION_PATCH[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$header" | head -1)
	echo "${major:-0}.${minor:-1}.${patch:-0}"
}

host_target() {
	# Host aliases → zig build release-pack triples
	# (tools/c-abi/c-abi-host-aliases.json). All aliases: x86_64 amd64 x64
	# aarch64 arm64 macos darwin macosx Darwin linux Linux windows win32.
	arch=$(uname -m 2>/dev/null || echo unknown)
	case "$arch" in
	amd64 | x64) arch=x86_64 ;;
	arm64) arch=aarch64 ;;
	esac

	os=$(uname -s 2>/dev/null || echo unknown)
	case "$os" in
	Darwin | macosx) os=macos ;;
	Linux) os=linux ;;
	MINGW* | MSYS* | CYGWIN* | win32) os=windows ;;
	*) os=$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]') ;;
	esac

	echo "$arch-$os"
}

# Platform shared-lib filename for marker_shared_stem.
shared_marker_name() {
	stem=$1
	case "$(uname -s 2>/dev/null || echo unknown)" in
	Darwin) echo "lib${stem}.dylib" ;;
	MINGW* | MSYS* | CYGWIN*) echo "${stem}.dll" ;;
	*) echo "lib${stem}.so" ;;
	esac
}

resolve_cache_base() {
	if [ -n "${PANCAKE_CACHE_DIR:-}" ]; then
		printf '%s' "$PANCAKE_CACHE_DIR"
	elif [ -n "${XDG_CACHE_HOME:-}" ]; then
		printf '%s' "$XDG_CACHE_HOME/pancake/c-abi"
	elif [ -n "${HOME:-}" ]; then
		printf '%s' "$HOME/.cache/pancake/c-abi"
	else
		printf '%s' "${TMPDIR:-/tmp}/$(contract fallback_cache_name)"
	fi
}

# Download URL to DEST with a size cap. Uses strict TLS unless ALLOW_INSECURE
# is set and the URL is not https.
download() {
	url=$1
	dest=$2
	max_bytes=$3

	if truthy "${PANCAKE_ALLOW_INSECURE:-}" && ! printf '%s' "$url" | grep -q '^https://'; then
		curl -fsSL --max-filesize "$max_bytes" -A "$UA" -o "$dest" "$url"
	else
		curl -fsSL --proto =https --tlsv1.2 \
			--max-filesize "$max_bytes" -A "$UA" -o "$dest" "$url"
	fi
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print tolower($1) }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print tolower($1) }'
	else
		return 1
	fi
}

# Member name from a `tar -tvzf` line (GNU or BSD), without " -> link target".
tar_member_name() {
	printf '%s' "$1" | sed 's/ -> .*//' | awk '{
		if (NF >= 8) {
			for (i = 8; i <= NF; i++)
				printf "%s%s", (i > 8 ? " " : ""), $i
			print ""
		} else {
			print $NF
		}
	}'
}

# Reject traversal and symlinks/hardlinks under extract_prefix (ADR-0077 §5).
# Hard-fails on unsafe/link members; soft-fails on tar list tooling failure.
# Runs in the main shell so hard_fail/soft_fail can terminate the script.
validate_tarball_members() {
	tarball=$1
	prefix=$2
	prefix_slash="${prefix}/"

	listing=$(tar -tvzf "$tarball") || soft_fail "tar list failed"

	# Keep fail helpers in this shell: a pipeline `while` would run in a subshell.
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue

		kind=$(printf '%s' "$line" | cut -c1)
		name=$(tar_member_name "$line")

		case "$name" in
		"$prefix" | "$prefix_slash"*) ;;
		*) continue ;;
		esac

		case "$name" in
		/* | *..*) hard_fail "refusing unsafe tar member: $name" ;;
		esac

		case "$kind" in
		l | h) hard_fail "refusing link tar member: $name" ;;
		esac
	done <<EOF
$listing
EOF
}

acquire_lock() {
	lock_dir=$1
	i=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 300 ] || soft_fail "timed out waiting for cache lock at $lock_dir"
		sleep 0.1
	done
}

# ---------------------------------------------------------------------------
# Args and prerequisites
# ---------------------------------------------------------------------------

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=${PANCAKE_REPO_ROOT:-$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)}
CONTRACT="$REPO_ROOT/bindings/c-abi-resolve.json"

VERSION=""
TARGET=""
while [ $# -gt 0 ]; do
	case "$1" in
	--version)
		[ $# -ge 2 ] || die_usage "--version needs a value"
		VERSION=$2
		shift 2
		;;
	--target)
		[ $# -ge 2 ] || die_usage "--target needs a value"
		TARGET=$2
		shift 2
		;;
	-h | --help)
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		die_usage "unknown argument: $1"
		;;
	esac
done

if truthy "${PANCAKE_SKIP_DOWNLOAD:-}"; then
	exit 0
fi

need_cmd jq
[ -f "$CONTRACT" ] || soft_fail "missing contract $CONTRACT"

jq -e '.require_https == true and .require_checksum == true' "$CONTRACT" >/dev/null \
	|| soft_fail "c-abi-resolve.json: require_https and require_checksum must be true"

# Prerelease valve: skip network until releases_published flips, unless the
# operator forces a rehearsal with PANCAKE_DOWNLOAD=1.
RELEASES_PUBLISHED=$(jq -r '.releases_published' "$CONTRACT")
if [ "$RELEASES_PUBLISHED" != "true" ] && ! truthy "${PANCAKE_DOWNLOAD:-}"; then
	echo "pancake fetch-c-abi: releases_published is false; set PANCAKE_DOWNLOAD=1 to fetch" >&2
	exit 0
fi

need_cmd curl
need_cmd tar

# ---------------------------------------------------------------------------
# Resolve version, target, URLs, and cache paths from the contract
# ---------------------------------------------------------------------------

[ -n "$VERSION" ] || VERSION=$(abi_version_from_header)
[ -n "$TARGET" ] || TARGET=$(host_target)

CACHE_BASE=$(resolve_cache_base)
BASE_URL=${PANCAKE_RELEASE_BASE_URL:-$(contract default_release_base_url)}
TAG=$(apply_contract_template "$(contract release_tag_template)")
TARBALL=$(apply_contract_template "$(contract tarball_template)")
CACHE_LIB=$(apply_contract_template "$(contract cache_layout)")
CACHE_ROOT=$(dirname "$CACHE_LIB")
URL="${BASE_URL}/${TAG}/${TARBALL}"

EXTRACT_PREFIX=$(contract extract_prefix)
UA=$(contract user_agent)
MAX_BYTES=$(contract max_tarball_bytes)
MAX_SUMS=$(contract max_sums_bytes)
# Contract marker fields (marker_static / shared stem) drive cache readiness.
MARKER_STATIC=$(jq -r .marker_static "$CONTRACT")
MARKER_SHARED=$(shared_marker_name "$(jq -r .marker_shared_stem "$CONTRACT")")

# ---------------------------------------------------------------------------
# Cache lock, then fetch → verify → extract
# ---------------------------------------------------------------------------

mkdir -p "$CACHE_ROOT"

LOCK_DIR="${CACHE_ROOT}/.lock"
acquire_lock "$LOCK_DIR"
cleanup_lock() {
	rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

# Another waiter may have finished while we waited for the lock.
if [ -f "$CACHE_LIB/$MARKER_STATIC" ] || [ -f "$CACHE_LIB/$MARKER_SHARED" ]; then
	exit 0
fi

TARBALL_PATH="${CACHE_ROOT}/${TARBALL}"
SUMS_PATH="${CACHE_ROOT}/SHA256SUMS"

case "$BASE_URL" in
https://*) ;;
*)
	if ! truthy "${PANCAKE_ALLOW_INSECURE:-}"; then
		hard_fail "refusing non-HTTPS release base URL: $BASE_URL"
	fi
	;;
esac

echo "pancake fetch-c-abi: downloading $URL" >&2
if ! download "$URL" "$TARBALL_PATH" "$MAX_BYTES"; then
	rm -f "$TARBALL_PATH"
	soft_fail "download failed: $URL"
fi

# Checksum is required before extract (release-pack publishes SHA256SUMS).
SUMS_URL="${BASE_URL}/${TAG}/SHA256SUMS"
if ! download "$SUMS_URL" "$SUMS_PATH" "$MAX_SUMS"; then
	rm -f "$TARBALL_PATH" "$SUMS_PATH"
	hard_fail "checksum required before extract: SHA256SUMS download failed"
fi

expect=$(awk -v f="$TARBALL" '$2 == f || $2 == ("*" f) { print tolower($1); exit }' "$SUMS_PATH" || true)
if [ -z "$expect" ]; then
	rm -f "$TARBALL_PATH"
	hard_fail "SHA256SUMS has no entry for $TARBALL"
fi

got=$(sha256_of "$TARBALL_PATH") || {
	rm -f "$TARBALL_PATH"
	soft_fail "neither sha256sum nor shasum on PATH"
}
if [ "$got" != "$expect" ]; then
	rm -f "$TARBALL_PATH"
	hard_fail "SHA256 mismatch for $TARBALL"
fi

STAGE="${CACHE_ROOT}/stage.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"

validate_tarball_members "$TARBALL_PATH" "$EXTRACT_PREFIX"

if ! tar -xzf "$TARBALL_PATH" -C "$STAGE" --no-same-owner "$EXTRACT_PREFIX"; then
	rm -rf "$STAGE"
	hard_fail "tar extract failed"
fi
if [ ! -d "$STAGE/$EXTRACT_PREFIX" ]; then
	rm -rf "$STAGE"
	hard_fail "tarball missing ${EXTRACT_PREFIX}/"
fi

rm -rf "$CACHE_LIB"
mv "$STAGE/$EXTRACT_PREFIX" "$CACHE_LIB"
rm -rf "$STAGE"

# Keep the tarball for offline re-extract; copy the contract next to it.
cp "$CONTRACT" "$CACHE_ROOT/c-abi-resolve.json" 2>/dev/null || true
exit 0
