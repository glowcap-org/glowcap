#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

# The upstream installer hardcodes its target to $HOME/.opencode/bin and has no
# override, so pin HOME to a shared image dir instead of root's home, then link
# the binary onto PATH the way install-claude-code.sh does.
mkdir -p "${OPENCODE_HOME}"
HOME="${OPENCODE_HOME}" VERSION="${OPENCODE_VERSION}" \
    bash -c 'curl -fsSL https://opencode.ai/install | bash'
chmod -R a+rX "${OPENCODE_HOME}"
ln -sf "${OPENCODE_HOME}/.opencode/bin/opencode" /usr/local/bin/opencode
opencode --version
