#!/usr/bin/env bash
# Prove that a release tarball works from an extracted, off-tree checkout.

set -euo pipefail

if [[ $# -ne 4 ]]; then
	printf 'usage: release-pack-smoke.sh TARBALL STATIC_NAMES SHARED_NAMES HEADERS\n' >&2
	exit 2
fi

archive=$1
read -r -a static_names <<<"$2"
read -r -a shared_names <<<"$3"
read -r -a header_names <<<"$4"
if [[ ! -f $archive ]]; then
	printf 'release-pack-smoke: archive not found: %s\n' "$archive" >&2
	exit 1
fi
if ! command -v zig >/dev/null 2>&1; then
	printf 'release-pack-smoke: zig is required to compile the C consumers\n' >&2
	exit 1
fi

archive_dir=$(CDPATH='' cd -- "$(dirname -- "$archive")" && pwd)
archive_name=$(basename -- "$archive")
case $archive_name in
	*.tar.gz) ;;
	*)
		printf 'release-pack-smoke: expected a .tar.gz archive: %s\n' "$archive_name" >&2
		exit 1
		;;
esac

if [[ ! -f $archive_dir/SHA256SUMS ]]; then
	printf 'release-pack-smoke: checksum manifest not found beside %s\n' "$archive_name" >&2
	exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
	(cd "$archive_dir" && sha256sum -c SHA256SUMS)
else
	(cd "$archive_dir" && shasum -a 256 -c SHA256SUMS)
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/pancake-release-pack.XXXXXX")
trap 'rm -rf -- "$workdir"' EXIT
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
. "$repo_root/tools/c-abi/archive-hygiene.sh"
if ! archive_hygiene_check "$archive_dir/$archive_name" ""; then
	printf 'release-pack-smoke: refusing unsafe release archive\n' >&2
	exit 1
fi
# Extract under the same locale and option set the listing validator saw.
# A hostile inherited TAR_OPTIONS must not hide a member from one operation or
# redirect the other, and archive ownership never crosses this boundary.
LC_ALL=C TAR_OPTIONS= tar -xzf "$archive_dir/$archive_name" -C "$workdir" --no-same-owner

readonly include_dir=$workdir/include
readonly lib_dir=$workdir/lib
for binary in pancake rooms-peer; do
	if [[ ! -x $workdir/bin/$binary ]]; then
		printf 'release-pack-smoke: missing executable product binary: bin/%s\n' "$binary" >&2
		exit 1
	fi
done

validate_identifier() {
	local kind=$1
	local name=$2
	if [[ ! $name =~ ^[a-z0-9_]+$ ]]; then
		printf 'release-pack-smoke: invalid %s name: %s\n' "$kind" "$name" >&2
		exit 1
	fi
}

for header in "${header_names[@]}"; do
	if [[ ! $header =~ ^[a-z0-9_]+\.h$ ]]; then
		printf 'release-pack-smoke: invalid header name: %s\n' "$header" >&2
		exit 1
	fi
	if [[ ! -f $include_dir/$header ]]; then
		printf 'release-pack-smoke: missing public header: include/%s\n' "$header" >&2
		exit 1
	fi
done

write_consumer() {
	local destination=$1
	shift
	local has_version=0
	local name transport
	for name in "$@"; do
		validate_identifier library "$name"
		if [[ $name == pancake_ocapn ]]; then
			has_version=1
		fi
	done
	{
		printf '#include <stddef.h>\n#include <stdint.h>\n'
		for header in "${header_names[@]}"; do
			printf '#include "%s"\n' "$header"
		done
		printf '%s\n' 'int main(void) {'
		if [[ $has_version -eq 1 ]]; then
			printf '%s\n' \
				'    uint32_t major = UINT32_MAX;' \
				'    uint32_t minor = UINT32_MAX;' \
				'    uint32_t patch = UINT32_MAX;'
		fi
		printf '%s\n' \
			'    volatile uint64_t fingerprints = 0;' \
			'    volatile size_t errors = 0;'
		for name in "$@"; do
			case $name in
				pancake_ocapn)
					printf '%s\n' '    pancake_abi_version(&major, &minor, &patch);'
					printf '%s\n' '    fingerprints ^= pancake_ocapn_archive_fingerprint();'
					;;
				pancake_host)
					printf '%s\n' \
						'    errors += pancake_host_last_error(NULL, 0);' \
						'    fingerprints ^= pancake_host_archive_fingerprint();'
					;;
				pancake_driver)
					printf '%s\n' \
						'    errors += pancake_driver_last_error(NULL, 0);' \
						'    fingerprints ^= pancake_driver_archive_fingerprint();'
					;;
				pancake_net_transport_*)
					transport=${name#pancake_net_transport_}
					printf '    fingerprints ^= pancake_%s_archive_fingerprint();\n' "$transport"
					;;
				*)
					printf 'release-pack-smoke: no safe consumer probe for library: %s\n' "$name" >&2
					exit 1
					;;
			esac
		done
		printf '%s\n' \
			'    (void)fingerprints;' \
			'    (void)errors;'
		if [[ $has_version -eq 1 ]]; then
			printf '%s\n' \
				'    return major != PANCAKE_VERSION_MAJOR ||' \
				'           minor != PANCAKE_VERSION_MINOR ||' \
				'           patch != PANCAKE_VERSION_PATCH;'
		else
			printf '%s\n' '    return 0;'
		fi
		printf '%s\n' '}'
	} >"$destination"
}

static_archives=()
for name in "${static_names[@]}"; do
	validate_identifier library "$name"
	static_archives+=("$lib_dir/lib$name.a")
done
shared_archives=()
for name in "${shared_names[@]}"; do
	validate_identifier library "$name"
	shared_archives+=("-l$name")
done

manifest_has() {
	local wanted=$1
	shift
	local name
	for name in "$@"; do
		if [[ $name == "$wanted" ]]; then
			return 0
		fi
	done
	return 1
}
if ! manifest_has pancake_ocapn "${static_names[@]}"; then
	printf 'release-pack-smoke: static manifest omits libpancake_ocapn\n' >&2
	exit 1
fi
if ! manifest_has pancake_ocapn "${shared_names[@]}"; then
	printf 'release-pack-smoke: shared manifest omits libpancake_ocapn\n' >&2
	exit 1
fi

case $(uname -s) in
	Linux)
		native_libraries=(-ldl -lpthread -lm)
		loader_variable=LD_LIBRARY_PATH
		shared_suffix=.so
		;;
	Darwin)
		native_libraries=(-lpthread -lm)
		loader_variable=DYLD_LIBRARY_PATH
		shared_suffix=.dylib
		;;
	*)
		printf 'release-pack-smoke: unsupported host OS: %s\n' "$(uname -s)" >&2
		exit 1
		;;
esac

for library in "${static_archives[@]}"; do
	if [[ ! -f $library ]]; then
		printf 'release-pack-smoke: missing static archive: %s\n' "${library#"$workdir/"}" >&2
		exit 1
	fi
done
for name in "${shared_names[@]}"; do
	if [[ ! -f $lib_dir/lib$name$shared_suffix ]]; then
		printf 'release-pack-smoke: missing shared library: lib/lib%s%s\n' "$name" "$shared_suffix" >&2
		exit 1
	fi
done

write_consumer "$workdir/shared-consumer.c" "${shared_names[@]}"

# Every Zig static archive is a self-contained product tier. Compile it alone:
# combining tiers asks the linker to define embedded lower-layer C symbols
# twice and proves a composition the archives neither advertise nor require.
for name in "${static_names[@]}"; do
	write_consumer "$workdir/static-$name-consumer.c" "$name"
	zig cc -std=c11 -Wall -Wextra -Werror -I"$include_dir" \
		"$workdir/static-$name-consumer.c" "$lib_dir/lib$name.a" "${native_libraries[@]}" \
		-o "$workdir/static-$name-consumer"
	"$workdir/static-$name-consumer"
done

zig cc -std=c11 -Wall -Wextra -Werror -I"$include_dir" \
	"$workdir/shared-consumer.c" -L"$lib_dir" \
	"${shared_archives[@]}" "${native_libraries[@]}" -o "$workdir/shared-consumer"
env "$loader_variable=$lib_dir" "$workdir/shared-consumer"

(cd "$workdir" && "$workdir/bin/pancake" --help >/dev/null)
(cd "$workdir" && "$workdir/bin/rooms-peer" --help >/dev/null)

printf 'release-pack-smoke: per-archive static consumers, shared consumer, and product binaries passed\n'
