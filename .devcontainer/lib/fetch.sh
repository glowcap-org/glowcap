# shellcheck shell=bash
# How an installer reaches the network, and how it decides a machine is one
# it can install for.
#
# Every file an installer downloads for itself comes through
# glowcap_fetch_verified and is checked against the SHA-256 pinned in
# checksums.sh, so it never runs bytes it did not name in advance.
#
# Some installers do not download for themselves. They hand the work to a
# package manager or an upstream installer that resolves and verifies against
# its own registry, which is why there is no tarball here for checksums.sh to
# name: npm, uv, raco, rustup, and Playwright's browser download each take a
# version pinned in pins.sh and check the bytes their own way. Where a
# bootstrap can be pinned, it is, so rust.sh verifies rustup-init here and lets
# rustup's signed manifest cover the toolchain. Where an ecosystem exposes the
# upstream checksum, the installer asserts it after the fact, as
# racket-goblins.sh does for the Goblins revision conformance answers to.

glowcap_verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ -z "${expected}" ]]; then
        echo "missing SHA-256 for ${file}" >&2
        return 1
    fi
    # macOS runners carry shasum, not sha256sum.
    if command -v sha256sum >/dev/null 2>&1; then
        echo "${expected}  ${file}" | sha256sum --check -
    else
        echo "${expected}  ${file}" | shasum -a 256 --check -
    fi
}

# Download a URL to a destination and verify it against a pinned SHA-256.
glowcap_fetch_verified() {
    local url="$1"
    local dest="$2"
    local sha256="$3"
    echo "downloading ${url}" >&2
    curl --fail --location --silent --show-error --output "${dest}" "${url}"
    glowcap_verify_sha256 "${dest}" "${sha256}"
}

# Select a per-architecture value: x86_64 value first, then aarch64. The
# mapping that calls this is the authority on which architectures its tool
# supports, so an unsupported machine fails here, at the point of use.
glowcap_pick_by_arch() {
    local label="$1"
    local x86_64_value="$2"
    local aarch64_value="$3"
    case "$(uname -m)" in
        x86_64) echo "${x86_64_value}" ;;
        aarch64) echo "${aarch64_value}" ;;
        *)
            echo "${label}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

# For installers with no per-architecture mapping of their own.
glowcap_require_arch() {
    case "$(uname -m)" in
        x86_64 | aarch64) return 0 ;;
        *)
            echo "${1}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
