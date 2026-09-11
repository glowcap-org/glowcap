# shellcheck shell=bash
# Which side of the container boundary a shell is on.
#
# The image exports GLOWCAP_DEVCONTAINER_DIR, present both during the build
# and inherited by every process in the running container — an attached
# editor shell and a docker exec alike — so that one variable decides the
# question. /.dockerenv and REMOTE_CONTAINERS deliberately do not count:
# they mark any container at all, and a container that runs its own Docker
# daemon (a cloud workspace, Docker-in-Docker) is a host for these scripts,
# because the host side exists to drive Docker and Docker answers there.
# Every script in this directory declares its side by calling one of the
# require helpers first thing, and a script that runs on both calls neither
# and says so in its header.
glowcap_in_devcontainer() {
    [[ -n "${GLOWCAP_DEVCONTAINER_DIR:-}" ]]
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
