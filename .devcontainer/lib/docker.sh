# shellcheck shell=bash
# What Docker holds for a checkout: its running container, and the side
# network it needs.
#
# Dev Containers labels a container with the exact host checkout it was
# created for, and that label is the authority here. A presentation name
# would select another clone of the same repository sooner or later.
glowcap_devcontainer_running_container() {
    local checkout="$1" ids count
    ids="$(docker ps --filter "label=devcontainer.local_folder=${checkout}" --format '{{.ID}}')" || return 1
    count="$(printf '%s\n' "${ids}" | sed '/^$/d' | wc -l | tr -d ' ')"
    case "${count}" in
        1) printf '%s\n' "${ids}" ;;
        0)
            echo "devcontainer: no running container is labeled for ${checkout}" >&2
            return 1
            ;;
        *)
            echo "devcontainer: multiple running containers are labeled for ${checkout}" >&2
            return 1
            ;;
    esac
}

glowcap_devcontainer_ensure_network() {
    local name="$1" ownership="$2"
    if docker network inspect "${name}" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "${ownership}" != managed ]]; then
        echo "devcontainer: Docker network '${name}' does not exist" >&2
        echo "devcontainer: create that external network, or remove .devcontainer/.env and run configure.sh for an isolated default" >&2
        return 1
    fi
    docker network create "${name}" >/dev/null 2>&1 ||
        docker network inspect "${name}" >/dev/null
}
