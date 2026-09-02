# shellcheck shell=bash
# Which side of the container boundary a shell is on.
#
# The image exports GLOWCAP_DEVCONTAINER_DIR, present both during the build
# and in the running container, and an attached editor shell or a docker exec
# sees /.dockerenv, so the question is decidable from either side. Every
# script in this directory declares its side by calling one of the require
# helpers first thing, and a script that runs on both calls neither and says
# so in its header.
glowcap_in_devcontainer() {
    [[ -n "${GLOWCAP_DEVCONTAINER_DIR:-}" || -f /.dockerenv || -n "${REMOTE_CONTAINERS:-}" ]]
}

glowcap_require_devcontainer() {
    if ! glowcap_in_devcontainer; then
        echo "$1: run this inside the devcontainer (or its image build); it relies on the image's pinned tools and paths" >&2
        return 1
    fi
}

glowcap_require_host() {
    if glowcap_in_devcontainer; then
        echo "$1: run this on the host, outside the devcontainer" >&2
        return 1
    fi
}
