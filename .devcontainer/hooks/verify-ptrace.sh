#!/usr/bin/env bash
# Confirm ptrace works for gdb and strace (requires compose cap_add / security_opt).

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_require_devcontainer "hooks/verify-ptrace"

tmp="$(mktemp -t pancake-ptrace-XXXXXX)"
trap 'rm -f "${tmp}" "${tmp}.c"' EXIT

cat > "${tmp}.c" <<'EOF'
#include <unistd.h>
int main(void) {
    _exit(0);
}
EOF
gcc -o "${tmp}" "${tmp}.c"
strace -e trace=execve -o /dev/null "${tmp}"
gdb -batch -ex 'set pagination off' -ex run -ex quit "${tmp}" >/dev/null
