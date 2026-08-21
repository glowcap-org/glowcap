# shellcheck shell=bash
# How an installer reaches the network, and how it decides a machine is one
# it can install for.
#
# Every remote byte the image build consumes arrives through
# pancake_fetch_verified and is checked against the SHA-256 pinned in
# checksums.sh, so an installer never runs bytes it did not name in advance.

pancake_verify_sha256() {
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
# Every remote byte an installer consumes comes through here.
pancake_fetch_verified() {
    local url="$1"
    local dest="$2"
    local sha256="$3"
    echo "downloading ${url}" >&2
    curl --fail --location --silent --show-error --output "${dest}" "${url}"
    pancake_verify_sha256 "${dest}" "${sha256}"
}

# Select a per-architecture value: x86_64 value first, then aarch64. The
# mapping that calls this is the authority on which architectures its tool
# supports, so an unsupported machine fails here, at the point of use.
pancake_pick_by_arch() {
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
pancake_require_arch() {
    case "$(uname -m)" in
        x86_64 | aarch64) return 0 ;;
        *)
            echo "${1}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
