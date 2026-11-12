#!/usr/bin/env bash
# A compiler pin move must also move both consumers of its shared cache path.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pins.sh
source "${dir}/pins.sh"
# shellcheck source=../lib/update-pins-companions.sh
source "${dir}/lib/update-pins-companions.sh"

scratch="$(mktemp -d)"
trap 'rm -rf -- "${scratch}"' EXIT
# Keep staging's temporary files inside the fixture it will remove.
export TMPDIR="${scratch}"
glowcap_pins_staged_companions=()
glowcap_pins_stage_companions zig "${ZIG_VERSION}" 99.0.0
for relative in .devcontainer/Dockerfile .devcontainer/devcontainer.json; do
    glowcap_pins_companion_stage_for "${relative}"
    grep -Fq 'tool/zig/99.0.0' "${glowcap_pins_companion_staged}"
    if grep -Fq "tool/zig/${ZIG_VERSION}" "${glowcap_pins_companion_staged}"; then
        echo "${relative}: compiler pin update retained the old cache" >&2
        exit 1
    fi
done
printf '%s\n' 'zig-cache-version: pin update moves both cache paths'
