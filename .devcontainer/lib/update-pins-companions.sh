# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Companion files. A few pins are restated outside pins.sh, because a
# Dockerfile and a deno.json cannot source a shell file. Each restatement is a
# row here naming the file, the exact text the old version produces, and the
# text the new one must produce. A bump rewrites every row or none, so the
# copies cannot fall out of step with the pin.
#
# .devcontainer/test/env-sync.sh reads these same rows and asserts each file
# already contains the text for the version pinned now, so a hand-edit that
# skips the bump fails `zig build check` instead of surviving to somebody's
# next rebuild. Because the check reads the table rather than repeating it, a
# row added here is checked from the next run with nothing else to update.
#
# Rows are tab-separated because every field here contains colons.
#
# Row paths are relative to the repository root, which this module reaches
# through `dir`, the .devcontainer directory its sourcing script located.
# ---------------------------------------------------------------------------

# Fail here, naming the contract, rather than letting an unset `dir` copy from
# a path that silently resolves somewhere else.
glowcap_pins_companion_source() {
    printf '%s\n' "${dir:?update-pins: companions.sh needs dir set by its caller}/../$1"
}

glowcap_pins_companions() {
    local dep="$1" old="$2" new="$3"
    case "${dep}" in
        zig)
            printf '%s\t%s\t%s\n' \
                build.zig.zon ".minimum_zig_version = \"${old}\"" ".minimum_zig_version = \"${new}\""
            ;;
        debian)
            printf '%s\t%s\t%s\n' \
                .devcontainer/Dockerfile "debian:${DEBIAN_BASE_TAG}@${old}" "debian:${DEBIAN_BASE_TAG}@${new}" \
                apps/rooms/web/deploy/rooms.Dockerfile "debian:${DEBIAN_BASE_TAG}@${old}" "debian:${DEBIAN_BASE_TAG}@${new}"
            ;;
        postgres)
            printf '%s\t%s\t%s\n' \
                apps/rooms/web/deploy/docker-compose.yml "postgres:${old}" "postgres:${new}"
            ;;
        python)
            printf '%s\t%s\t%s\n' \
                conformance/ocapn-conformance/pyproject.toml \
                "requires-python = \"==${old%.*}.*\"" \
                "requires-python = \"==${new%.*}.*\"" \
                conformance/keri-conformance/run.sh \
                "--python ${old%.*}" \
                "--python ${new%.*}"
            ;;
        playwright)
            # Every Deno scope that drives a browser resolves its playwright
            # import from the same number; source-check fails if any disagrees.
            # Each scope's frozen deno.lock restates the version too, and only
            # Deno can rewrite those: after the bump, run
            # `deno install --frozen=false` in each scope listed here.
            printf '%s\t%s\t%s\n' \
                deno.json "npm:playwright@${old}" "npm:playwright@${new}" \
                bindings/ts/deno.json "npm:playwright@${old}" "npm:playwright@${new}" \
                apps/ocapnviz/deno.json "npm:playwright@${old}" "npm:playwright@${new}"
            ;;
    esac
}

# Point `glowcap_pins_companion_staged` at the staged copy of one companion
# file, taken from disk the first time it is asked for and reused after that.
# Two deps can restate their pins in the same file, as the rooms image does with
# the base image and Deno, so a later edit has to build on the earlier one.
# Staging each from the original would let whichever landed last drop the
# other's change.
#
# It answers through a variable rather than stdout because a command
# substitution runs in a subshell, where the append below would be discarded.
glowcap_pins_companion_staged=""
glowcap_pins_companion_stage_for() {
    local relative="$1" row candidate staged
    for row in "${glowcap_pins_staged_companions[@]:-}"; do
        [[ -n "${row}" ]] || continue
        IFS=$'\t' read -r candidate staged <<< "${row}"
        if [[ "${candidate}" == "${relative}" ]]; then
            glowcap_pins_companion_staged="${staged}"
            return 0
        fi
    done
    staged="$(mktemp -t glowcap-companion-XXXXXX)"
    cp "$(glowcap_pins_companion_source "${relative}")" "${staged}"
    glowcap_pins_staged_companions+=("${relative}"$'\t'"${staged}")
    glowcap_pins_companion_staged="${staged}"
}

# Stage every companion of one dep. Replacement is literal text, never a
# pattern, because a version string carries dots that a regex would widen.
glowcap_pins_stage_companions() {
    local dep="$1" old="$2" new="$3" old_digest="${4:-}" new_digest="${5:-}"
    local relative from to staged edited
    while IFS=$'\t' read -r relative from to; do
        [[ -n "${relative}" ]] || continue
        glowcap_pins_companion_stage_for "${relative}"
        staged="${glowcap_pins_companion_staged}"
        edited="$(mktemp -t glowcap-companion-edit-XXXXXX)"
        awk -v from="${from}" -v to="${to}" '
            {
                rest = $0
                out = ""
                at = index(rest, from)
                while (at > 0) {
                    out = out substr(rest, 1, at - 1) to
                    rest = substr(rest, at + length(from))
                    hits++
                    at = index(rest, from)
                }
                print out rest
            }
            END { if (!hits) exit 3 }
        ' "${staged}" > "${edited}" || {
            echo "update-pins: ${relative}: no '${from}' to replace" >&2
            rm -f "${edited}"
            return 1
        }
        mv "${edited}" "${staged}"
    done < <(glowcap_pins_companions "${dep}" "${old}" "${new}" "${old_digest}" "${new_digest}")
}
