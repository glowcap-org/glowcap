#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "install-racket-goblins"

racket_dir="/opt/racket-${RACKET_VERSION}"
tmp="$(mktemp -d -t pancake-racket-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

mapfile -t racket_asset < <(racket_tarball_and_sha256)
tarball="${racket_asset[0]}"
sha256="${racket_asset[1]}"
url="https://download.racket-lang.org/releases/${RACKET_VERSION}/installers/${tarball}"

fetch_verified "${url}" "${tmp}/${tarball}" "${sha256}"

mkdir -p "${racket_dir}"
tar -xzf "${tmp}/${tarball}" --strip-components=1 -C "${racket_dir}"
ln -sf "${racket_dir}/bin/racket" /usr/local/bin/racket
ln -sf "${racket_dir}/bin/raco" /usr/local/bin/raco

racket --version | grep -q "${RACKET_VERSION}"
command -v raco >/dev/null

mkdir -p "${PLTUSERHOME}"
export PLTUSERHOME

echo "installing Spritely Goblins ${GOBLINS_VERSION} into ${PLTUSERHOME}" >&2
raco pkg install --auto --batch --no-setup \
    --checksum "${UNIX_SOCKET_LIB_CHECKSUM}" \
    unix-socket-lib
raco pkg install --auto --batch --no-setup \
    --checksum "${CRYPTO_LIB_CHECKSUM}" \
    crypto-lib
raco pkg install --auto --batch --no-setup \
    --checksum "${CRYPTO_LIB_CHECKSUM}" \
    crypto
raco pkg install --auto --batch --no-setup \
    --checksum "${GOBLINS_CHECKSUM}" \
    "${GOBLINS_SOURCE}"

# The Racket relay (bindings/racket/relay.rkt, ADR-0086) serves WebSockets over
# net/rfc6455; the pinned toolchain does not ship it, so add it for the
# bindings-relay matrix's Racket row.
raco pkg install --auto --batch --no-setup \
    --checksum "${RFC6455_CHECKSUM}" \
    rfc6455

user_pkgs_dir="$(racket --eval \
    '(begin (require setup/dirs) (display (path->string (find-user-pkgs-dir))))' \
    2>/dev/null)"
if [[ -z "${user_pkgs_dir}" ]]; then
    echo "could not resolve Racket user package directory" >&2
    exit 1
fi

crypto_ffi="${user_pkgs_dir}/crypto-lib/private/libcrypto3/ffi.rkt"
if [[ ! -f "${crypto_ffi}" ]]; then
    echo "crypto-lib ffi.rkt not found at ${crypto_ffi}" >&2
    exit 1
fi

echo "patching crypto-lib atomic primitive names" >&2
verify_sha256 "${crypto_ffi}" "${CRYPTO_LIB_FFI_SOURCE_SHA256}"
patch --directory "${user_pkgs_dir}" --strip=1 \
    < "${dir}/patches/crypto-lib-racket-9.2.patch"
verify_sha256 "${crypto_ffi}" "${CRYPTO_LIB_FFI_PATCHED_SHA256}"

raco setup --no-docs --pkgs unix-socket-lib goblins crypto-lib crypto
racket --eval '(require racket/unix-socket)'
racket --eval '(require crypto)'
raco pkg show --long goblins | grep -q "${GOBLINS_CHECKSUM}"
raco pkg show --all --long unix-socket-lib | grep -q "${UNIX_SOCKET_LIB_CHECKSUM}"
raco pkg show --all --long rfc6455 | grep -q "${RFC6455_CHECKSUM}"
raco pkg show --all --long crypto-lib | grep -q "${CRYPTO_LIB_CHECKSUM}"
raco pkg show --all --long crypto | grep -q "${CRYPTO_LIB_CHECKSUM}"

chmod -R a+rX "${PLTUSERHOME}"
