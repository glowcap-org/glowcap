# shellcheck shell=bash
# The shared shell library for this directory, and its front door: sourcing
# this one file brings in the modules below. Scripts on both sides of the
# container boundary source it, so everything it loads stays portable to the
# host's bash, which on macOS is still 3.2.
#
# One module per subject. Read the one for the subject you are changing:
#
#   context.sh    which side of the container boundary a shell is on
#   names.sh      the worktree, session, and network name grammars
#   settings.sh   pinned versions, ports, host state, Compose variables
#   checkout.sh   which checkout is which, according to Git
#   env.sh        the ignored .env a checkout carries
#   docker.sh     the container and network Docker holds for a checkout
#   fetch.sh      verified downloads and architecture selection
#
# launcher.sh sits beside them and is not loaded here: it is useful only on
# the host, so the two tmux launchers source it directly and it pulls this
# file in for them. The update-pins-*.sh modules sit beside them on the same
# terms, sourced only by bin/update-pins.sh, so a pin bump's machinery is not
# loaded into every shell that reads a pin, and playwright.sh likewise,
# sourced only by the image verifier and its test.
#
# Each module is named on its own line rather than looped over, because a
# path shellcheck cannot resolve is a module it cannot read: every consumer
# of this library would lose sight of everything behind the loop.
glowcap_devcontainer_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=context.sh
source "${glowcap_devcontainer_lib_dir}/context.sh"
# shellcheck source=names.sh
source "${glowcap_devcontainer_lib_dir}/names.sh"
# shellcheck source=settings.sh
source "${glowcap_devcontainer_lib_dir}/settings.sh"
# shellcheck source=checkout.sh
source "${glowcap_devcontainer_lib_dir}/checkout.sh"
# shellcheck source=env.sh
source "${glowcap_devcontainer_lib_dir}/env.sh"
# shellcheck source=docker.sh
source "${glowcap_devcontainer_lib_dir}/docker.sh"
# shellcheck source=fetch.sh
source "${glowcap_devcontainer_lib_dir}/fetch.sh"
unset glowcap_devcontainer_lib_dir

# Load a checkout's pinned versions and paths. Call it after sourcing this
# file, with the .devcontainer directory to read them from; pass `checksums`
# as well when the caller downloads something and needs the hashes.
glowcap_devcontainer_init() {
    local root="$1"
    local with_checksums="${2:-}"
    if [[ "${with_checksums}" == checksums ]]; then
        # shellcheck disable=SC1091
        source "${root}/checksums.sh"
    fi
    glowcap_devcontainer_source_pins "${root}"
}
