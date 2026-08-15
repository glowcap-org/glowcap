#!/usr/bin/env bash
# Start or rebuild the pancake devcontainer from a host shell.
#
# The editor commands and this script share one engine, the devcontainer CLI
# (@devcontainers/cli), so these are the same operations:
#
#   bash .devcontainer/up.sh              "Dev Containers: Reopen in Container"
#   bash .devcontainer/up.sh --rebuild    "Dev Containers: Rebuild Container"
#   bash .devcontainer/up.sh --no-cache   "Dev Containers: Rebuild Container Without Cache"
#
# The CLI runs the whole lifecycle the editor would: initialize.sh on the host,
# the compose build and up, the devcontainer features, and post-create.sh in
# the container. The result carries the compose project name and labels the
# editor computes from this folder, so VS Code or Cursor attaches to it, reuses
# it, or rebuilds it as if the editor had created it. The one editor-only step
# left is installing the editor's own server and extensions, which happens on
# first attach.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "${dir}")"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

# The header comment above is the usage text: print it from the line after the
# shebang to the first non-comment line, so editing the header cannot strand a
# line-number range.
usage() {
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

mode="up"
for argument in "$@"; do
    case "${argument}" in
        --rebuild | --no-cache)
            requested_mode="${argument#--}"
            if [[ "${mode}" != up && "${mode}" != "${requested_mode}" ]]; then
                echo "up.sh: --rebuild and --no-cache are mutually exclusive" >&2
                exit 2
            fi
            mode="${requested_mode}"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "up.sh: unknown argument: ${argument}" >&2
            usage >&2
            exit 2
            ;;
    esac
done

pancake_require_host "up.sh"

if [[ ! -e "${dir}/.env" ]]; then
    bash "${dir}/configure.sh"
fi
worktree_name="$(pancake_devcontainer_validate_checkout_env "${dir}")"

command -v docker >/dev/null || {
    echo "up.sh: docker is not on PATH" >&2
    exit 1
}

# Use an installed CLI only when it matches the repository pin. Otherwise npx
# supplies the pinned engine, so host setup cannot silently change semantics.
if command -v devcontainer >/dev/null; then
    installed_version="$(devcontainer --version)"
else
    installed_version=""
fi
if [[ "${installed_version}" == "${DEVCONTAINER_CLI_VERSION}" ]]; then
    cli=(devcontainer)
elif command -v npx >/dev/null; then
    cli=(npx -y "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}")
else
    echo "up.sh: needs devcontainer CLI ${DEVCONTAINER_CLI_VERSION} or npx to run that pinned version" >&2
    exit 1
fi

args=(up --workspace-folder "${repo}")
case "${mode}" in
    rebuild) args+=(--remove-existing-container) ;;
    no-cache) args+=(--remove-existing-container --build-no-cache) ;;
    up) ;;
esac

exec "${cli[@]}" "${args[@]}"
