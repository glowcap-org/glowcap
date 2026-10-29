#!/usr/bin/env bash
# Free hosted-runner disk before the toolchain image is pulled or built.
# Caller: the first step of every workflow job that starts the devcontainer
# (the CI start action, the image composite action, pages.yml,
# agent-tools.yml). No arguments; NEED_GB overrides the free space a job
# needs. Prints the root filesystem before and after, exits non-zero only when
# a removal fails.
#
# Removal takes minutes, so it runs only when the root filesystem has less
# free space than a job needs. The 60 GB default is several times what a
# compile or test job adds, restored state and the container image included.
#
# The SDKs below belong to the disposable runner; every product tool comes
# from the devcontainer. The runner's node, python3, docker, and git stay,
# because the Dev Containers CLI and the workflow steps run on them, and the
# hosted toolcache keeps its Python and Node trees for setup-python callers.
set -euo pipefail

need=${NEED_GB:-60}
df -h /
free=$(df --output=avail --block-size=1G / | tail -1 | tr -d ' ')
if [ "$free" -ge "$need" ]; then
  echo "${free} GB free of the ${need} GB a job needs; keeping the runner's SDKs."
  exit 0
fi
sudo rm -rf \
  /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
  /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/go /opt/hostedtoolcache/Ruby /opt/hostedtoolcache/PyPy \
  /usr/share/swift /usr/lib/jvm /usr/share/miniconda /usr/local/julia* \
  /usr/local/share/powershell /usr/local/share/chromium \
  /opt/az /usr/local/aws-cli /usr/local/aws-sam-cli /usr/lib/google-cloud-sdk /usr/share/kotlinc
# Preinstalled images the runner ships for other ecosystems.
docker image prune --all --force >/dev/null
df -h /
