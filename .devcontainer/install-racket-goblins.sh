#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
require_arch "racket"

racket_dir="/opt/racket-${RACKET_VERSION}"
tmp="$(mktemp -d -t pancake-racket-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

mapfile -t racket_asset < <(racket_tarball_and_sha256)
tarball="${racket_asset[0]}"
sha256="${racket_asset[1]}"
url="https://download.racket-lang.org/releases/${RACKET_VERSION}/installers/${tarball}"

echo "downloading ${url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${tarball}" "${url}"
verify_download_sha256 "${tmp}/${tarball}" "${sha256}"

mkdir -p "${racket_dir}"
tar -xzf "${tmp}/${tarball}" --strip-components=1 -C "${racket_dir}"
ln -sf "${racket_dir}/bin/racket" /usr/local/bin/racket
ln -sf "${racket_dir}/bin/raco" /usr/local/bin/raco

racket --version | grep -q "${RACKET_VERSION}"
command -v raco >/dev/null

mkdir -p "${PLTUSERHOME}"
export PLTUSERHOME

echo "installing Spritely Goblins ${GOBLINS_VERSION} into ${PLTUSERHOME}" >&2
raco pkg install --auto --batch --no-setup unix-socket-lib
raco pkg install --auto --batch --no-setup \
    --checksum "${GOBLINS_CHECKSUM}" \
    "${GOBLINS_SOURCE}"

# The Racket relay (bindings/racket/relay.rkt, ADR-0086) serves WebSockets over
# net/rfc6455; the pinned toolchain does not ship it, so add it for the
# bindings-relay matrix's Racket row.
raco pkg install --auto --batch --no-setup rfc6455

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
sed -i \
    -e 's/end-uninterruptible/end-atomic/g' \
    -e 's/start-uninterruptible/start-atomic/g' \
    "${crypto_ffi}"
grep -q 'ffi/unsafe/atomic' "${crypto_ffi}" \
    || sed -i '/^#lang racket\/base/a (require ffi/unsafe/atomic)' "${crypto_ffi}"

raco setup --no-docs --pkgs unix-socket-lib goblins crypto-lib crypto
racket --eval '(require racket/unix-socket)'
racket --eval '(require crypto)'
raco pkg show --long goblins | grep -q "#v${GOBLINS_VERSION}"

chmod -R a+rX "${PLTUSERHOME}"
