#!/usr/bin/env bash
# Free hosted-runner disk before the toolchain image is pulled or built.
# Caller: the first step of every workflow job that starts the devcontainer
# (check.yml lanes, the image composite action, pages.yml, agent-tools.yml).
# No arguments or environment inputs. Prints the root filesystem before and
# after, exits non-zero only when a removal fails.
#
# The SDKs below belong to the disposable runner; every product tool comes
# from the devcontainer. The runner's node, python3, docker, and git stay,
# because the Dev Containers CLI and the workflow steps run on them, and the
# hosted toolcache keeps its Python and Node trees for setup-python callers.
set -euo pipefail

df -h /
sudo rm -rf \
  /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
  /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/go /opt/hostedtoolcache/Ruby /opt/hostedtoolcache/PyPy \
  /usr/share/swift /usr/lib/jvm /usr/share/miniconda /usr/local/julia* \
  /usr/local/share/powershell /usr/local/share/chromium \
  /opt/az /usr/local/aws-cli /usr/local/aws-sam-cli /usr/lib/google-cloud-sdk /usr/share/kotlinc
# Preinstalled images the runner ships for other ecosystems.
docker image prune --all --force >/dev/null
df -h /
