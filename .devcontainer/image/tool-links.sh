#!/usr/bin/env bash
# Link the managed-tool dispatcher onto PATH. The managed command names come
# from the registry, and every link points into the workspace checkout, whose
# tools runtime serves this container. The links dangle during the image
# build and resolve when the workspace bind lands, exactly like the repo-root
# glowcap shim. No harness is downloaded here: installation is first use.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/tool-links"

# shellcheck source=../tools/lib/registry.sh
source "${dir}/tools/lib/registry.sh"
bash -n "${dir}/tools/lib/lifecycle.sh" "${dir}/tools/wrapper.sh" "${dir}/bin/tools.sh"

for name in $(glowcap_tools_path_names); do
    ln -s /workspaces/glowcap/.devcontainer/tools/wrapper.sh "/usr/local/bin/${name}"
done
