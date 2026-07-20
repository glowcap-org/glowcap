# Shared helpers for devcontainer install, verify, and config checks.

pancake_devcontainer_source_pins() {
    local root="$1"
    # shellcheck disable=SC1091
    source "${root}/pins.sh"
    pancake_devcontainer_validate_pins
}

pancake_devcontainer_validate_pins() {
    if [[ "${ZIG_VERSION}" != "${ZLS_VERSION}" ]]; then
        echo "pins.sh: ZIG_VERSION (${ZIG_VERSION}) must equal ZLS_VERSION (${ZLS_VERSION})" >&2
        return 1
    fi
}

# Call after sourcing lib.sh. Optional second argument: checksums
pancake_devcontainer_init() {
    local root="$1"
    local with_checksums="${2:-}"
    if [[ "${with_checksums}" == checksums ]]; then
        # shellcheck disable=SC1091
        source "${root}/checksums.sh"
    fi
    pancake_devcontainer_source_pins "${root}"
}

verify_download_sha256() {
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

require_arch() {
    case "$(uname -m)" in
        x86_64 | aarch64) return 0 ;;
        *)
            echo "${1}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

linux_cpu() {
    case "$(uname -m)" in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        *)
            echo "unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
