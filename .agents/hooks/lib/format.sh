#!/usr/bin/env bash
# glowcap: Format files in place by extension, shared by the edit hook and the pre-commit hook.
#
# Callers: .agents/hooks/format-edited-file.sh (one file after an agent edit)
# and .agents/hooks/pre-commit (the staged files, on the host or through the
# devcontainer front, which runs this file directly).
#
# Source it for the functions, or run it with files as arguments:
#   format.sh FILE...                formats each file, exits 1 if any formatter fails
#   glowcap_format_missing_tools FILE...   prints each formatter FILE... needs and PATH lacks
#   glowcap_format_files FILE...           formats; formatter output goes to stderr
#
# Formatters by extension:
#   .zig                      zig fmt
#   .rs                       rustfmt --config skip_children=true, once per file
#   .ts .tsx .js .mjs         deno fmt, run from the nearest directory holding a
#                             deno.json, once per directory, so each Deno scope's
#                             fmt block applies
#   .py                       ruff format --force-exclude, from the caller's
#                             directory (the pre-commit hook passes the
#                             repository root, and ruff finds ruff.toml by path)
# Any other extension is ignored. Relative paths resolve against the caller's
# directory. Racket has no single-file formatter, so `bindings-fmt-check` owns it.
#
# Exit status: 0 when every formatter succeeded, 1 otherwise. A missing
# formatter and a formatter that rejects its input both print their message and
# set status 1, and the remaining formatters still run. Written for bash 3.2
# and options GNU and BSD tools share, because infrastructure-check runs it on
# macOS.

# The formatter a path needs, or nothing for an unsupported extension.
glowcap_format_tool_for() {
  case "$1" in
    *.zig) printf 'zig\n' ;;
    *.rs) printf 'rustfmt\n' ;;
    *.ts | *.tsx | *.js | *.mjs) printf 'deno\n' ;;
    *.py) printf 'ruff\n' ;;
  esac
}

# True when the path has an extension this library formats.
glowcap_format_supports() {
  [[ -n "$(glowcap_format_tool_for "$1")" ]]
}

# Print each distinct formatter the files need that is not on PATH.
glowcap_format_missing_tools() {
  local seen=" " file tool
  for file in "$@"; do
    tool="$(glowcap_format_tool_for "${file}")"
    [[ -n "${tool}" ]] || continue
    [[ "${seen}" == *" ${tool} "* ]] && continue
    seen="${seen}${tool} "
    command -v "${tool}" >/dev/null 2>&1 || printf '%s\n' "${tool}"
  done
}

# The absolute path for a path that exists, with its directory resolved.
glowcap_format_absolute() {
  local dir
  dir="$(cd "$(dirname "$1")" && pwd -P)" || return 1
  printf '%s/%s\n' "${dir}" "$(basename "$1")"
}

# The nearest directory at or above the file's own that holds a deno.json, or
# the file's directory when none does.
glowcap_format_deno_scope() {
  local dir
  dir="$(dirname "$1")"
  while [[ "${dir}" != "/" && "${dir}" != "." ]]; do
    if [[ -f "${dir}/deno.json" ]]; then
      printf '%s\n' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  dirname "$1"
}

# Format the files in place. See the header for the contract.
glowcap_format_files() {
  local status=0 file abs tool i j scope
  local zig_files=() py_files=() deno_files=() deno_scopes=() scopes_done=() group=()

  for file in "$@"; do
    tool="$(glowcap_format_tool_for "${file}")"
    [[ -n "${tool}" ]] || continue
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf 'glowcap format: %s is not on PATH, so %s is not formatted\n' "${tool}" "${file}" >&2
      status=1
      continue
    fi
    if ! abs="$(glowcap_format_absolute "${file}")"; then
      printf 'glowcap format: cannot resolve %s\n' "${file}" >&2
      status=1
      continue
    fi
    case "${tool}" in
      zig) zig_files+=("${abs}") ;;
      ruff) py_files+=("${abs}") ;;
      rustfmt)
        # Discover the file's config, but never walk its child modules: this
        # library owns only the files it was given.
        rustfmt --config skip_children=true "${abs}" >&2 || status=1
        ;;
      deno)
        deno_files+=("${abs}")
        deno_scopes+=("$(glowcap_format_deno_scope "${abs}")")
        ;;
    esac
  done

  if [[ ${#zig_files[@]} -gt 0 ]]; then
    zig fmt "${zig_files[@]}" >&2 || status=1
  fi
  if [[ ${#py_files[@]} -gt 0 ]]; then
    ruff format --force-exclude "${py_files[@]}" >&2 || status=1
  fi

  # One deno run per scope. Collect that scope's files into a fresh list, so
  # the scope's own deno.json decides the format.
  for ((i = 0; i < ${#deno_files[@]}; i++)); do
    scope="${deno_scopes[i]}"
    [[ "${scopes_done[*]-}" == *"|${scope}|"* ]] && continue
    scopes_done+=("|${scope}|")
    group=()
    for ((j = i; j < ${#deno_files[@]}; j++)); do
      [[ "${deno_scopes[j]}" == "${scope}" ]] && group+=("${deno_files[j]}")
    done
    (cd "${scope}" && deno fmt --permit-no-files "${group[@]}") >&2 || status=1
  done

  return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  glowcap_format_files "$@"
fi
