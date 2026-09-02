#!/usr/bin/env bash
# Manage the devcontainer's pinned dependency versions.
#
#   update-pins.sh [check]         report every pin against upstream, and
#                                  submodule drift; writes nothing
#   update-pins.sh bump <dep>...   rewrite pins.sh, checksums.sh, and every
#                                  file restating one of those pins
#   update-pins.sh bump --safe     bump every dep outside the build graph,
#                                  the ones a rebuild alone proves
#
# Versions and hashes come from each tool's own release channel (ziglang.org,
# static.rust-lang.org, the GitHub releases API, registry.npmjs.org,
# nodejs.org, pypi.org, download.racket-lang.org, codeberg.org,
# registry-1.docker.io). Edits go through staged copies that are validated
# whole (bash syntax, hash shape, anchored replacement) before they land, so a
# bump that cannot rewrite one of its files changes none of them. pins.sh
# lands last, which means an interruption can leave inert future hashes and
# companion files a step ahead of the pin, never a version whose hash and
# Dockerfiles still name the release before it. Run it in the devcontainer,
# where curl, jq, git, and uv are pinned.
#
# Every bump ends with a container rebuild; check prints which build gate
# proves each outdated dep beyond that. racket and goblins are generation
# moves (conformance authority), so bump prints their procedure instead of
# editing.
#
# check exits 0 when everything is current, 1 when updates are available,
# 2 when any upstream query failed.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "update-pins"

# This script's own modules, one per subject. They live in lib/ with the rest of
# the sourced shell and stay out of mod.sh, the way launcher.sh does, because
# only this script needs them. Each is named on its own line so shellcheck can
# follow it:
#
#   update-pins-deps.sh        what is tracked, and each release channel
#   update-pins-staging.sh     staged edits to pins.sh and checksums.sh
#   update-pins-companions.sh  the files outside pins.sh that restate a pin
# shellcheck source=../lib/update-pins-deps.sh
source "${dir}/lib/update-pins-deps.sh"
# shellcheck source=../lib/update-pins-staging.sh
source "${dir}/lib/update-pins-staging.sh"
# shellcheck source=../lib/update-pins-companions.sh
source "${dir}/lib/update-pins-companions.sh"

usage() {
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

submodule_drift() {
    local drift=0 sha path url head rest
    while read -r sha path rest; do
        sha="${sha#[+-]}"
        url="$(git -C "${dir}/.." config --file .gitmodules "submodule.${path}.url")"
        head="$(git ls-remote "${url}" HEAD 2>/dev/null | cut -f1)" || head=""
        if [[ -z "${head}" ]]; then
            printf '  %-28s upstream query failed (%s)\n' "${path##conformance/}" "${url}"
            drift=2
        elif [[ "${head}" != "${sha}" ]]; then
            printf '  %-28s pinned %.12s, upstream %.12s\n' "${path##conformance/}" "${sha}" "${head}"
            [[ "${drift}" -eq 2 ]] || drift=1
        fi
    done < <(git -C "${dir}/.." submodule status)
    return "${drift}"
}

# Digests and git revisions are far too long for a column, so they show as a
# recognizable prefix. Every ordinary version stays whole: truncating those is
# what let a Zig dev build read as unchanged on a row whose verdict said an
# update was waiting, and a reader who cannot trust the columns cannot use the
# report.
display_version() {
    case "$1" in
        sha256:*) printf 'sha256:%.12s...\n' "${1#sha256:}" ;;
        *)
            if [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
                printf '%.12s...\n' "$1"
            else
                printf '%s\n' "$1"
            fi
            ;;
    esac
}

run_check() {
    local status=0 dep var pinned latest verdict
    printf '%-18s %-26s %-26s %s\n' DEP PINNED LATEST VERDICT
    for dep in ${GLOWCAP_PINS_DEPS}; do
        var="$(glowcap_pins_dep_var "${dep}")"
        pinned="${!var}"
        latest="$(glowcap_pins_latest_version "${dep}" 2>/dev/null)" || latest=""
        if [[ -z "${latest}" ]]; then
            verdict="upstream query failed"
            status=2
        elif [[ "${latest}" == "${pinned}" ]]; then
            verdict="current"
        else
            verdict="update available ($(glowcap_pins_dep_class "${dep}")); gate: $(glowcap_pins_dep_gate "${dep}")"
            [[ "${status}" -eq 2 ]] || status=1
        fi
        printf '%-18s %-26s %-26s %s\n' "${dep}" \
            "$(display_version "${pinned}")" "$(display_version "${latest:--}")" "${verdict}"
    done
    echo
    echo "submodules (report-only; moving one answers to zig build check-external):"
    local sub_status=0
    submodule_drift || sub_status=$?
    if [[ "${sub_status}" -eq 0 ]]; then
        echo "  all at upstream HEAD"
    elif [[ "${sub_status}" -eq 2 ]]; then
        status=2
    elif [[ "${status}" -eq 0 ]]; then
        status=1
    fi
    return "${status}"
}

# ---------------------------------------------------------------------------
# bump
# ---------------------------------------------------------------------------

run_bump() {
    local dep var pinned latest class changed="" gates="" deno_image_digest=""
    # The staged paths stay global: the EXIT trap fires after this function's
    # locals are gone, and a moved file is a harmless rm -f no-op.
    staged_pins="$(mktemp -t glowcap-pins-XXXXXX)"
    staged_sums="$(mktemp -t glowcap-checksums-XXXXXX)"
    glowcap_pins_staged_companions=()
    trap 'rm -f "${staged_pins:-}" "${staged_sums:-}" \
        $(printf "%s\n" "${glowcap_pins_staged_companions[@]:-}" | cut -f2)' EXIT
    cp "${dir}/pins.sh" "${staged_pins}"
    cp "${dir}/checksums.sh" "${staged_sums}"

    for dep in "$@"; do
        var="$(glowcap_pins_dep_var "${dep}")"
        class="$(glowcap_pins_dep_class "${dep}")"
        if [[ "${class}" == manual ]]; then
            glowcap_pins_manual_procedure "${dep}"
            return 1
        fi
        pinned="${!var}"
        latest="$(glowcap_pins_latest_version "${dep}")"
        if [[ -z "${latest}" ]]; then
            echo "update-pins: ${dep}: upstream query failed" >&2
            return 2
        fi
        if [[ "${latest}" == "${pinned}" ]]; then
            echo "${dep}: already ${pinned}"
            continue
        fi
        if [[ "${dep}" == zig ]]; then
            glowcap_pins_stage_zls_source "${staged_pins}" "$(glowcap_pins_latest_version zls)"
        fi
        if [[ "${dep}" == zls ]]; then
            glowcap_pins_stage_zls_source "${staged_pins}" "${latest}"
            changed="${changed}${changed:+, }${dep} ${pinned} -> ${latest}"
            gates="${gates}  - $(glowcap_pins_dep_gate "${dep}")"$'\n'
            echo "${dep}: ${pinned} -> ${latest}"
            continue
        fi
        if [[ "${dep}" == deno ]]; then
            deno_image_digest="$(glowcap_pins_docker_hub_index_digest denoland/deno "bin-${latest}")"
            if ! [[ "${deno_image_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
                echo "update-pins: deno image index is not a SHA-256: '${deno_image_digest}'" >&2
                return 1
            fi
            glowcap_pins_stage_companions \
                "${dep}" "${pinned}" "${latest}" "${DENO_IMAGE_DIGEST}" "${deno_image_digest}"
            glowcap_pins_replace_line "${staged_pins}" DENO_IMAGE_DIGEST "${deno_image_digest}"
        else
            glowcap_pins_stage_companions "${dep}" "${pinned}" "${latest}"
        fi
        glowcap_pins_replace_line "${staged_pins}" "${var}" "${latest}"
        glowcap_pins_refresh_hashes "${dep}" "${latest}" "${staged_sums}"
        changed="${changed}${changed:+, }${dep} ${pinned} -> ${latest}"
        gates="${gates}  - $(glowcap_pins_dep_gate "${dep}")"$'\n'
        echo "${dep}: ${pinned} -> ${latest}"
    done

    if [[ -z "${changed}" ]]; then
        echo "nothing to do"
        return 0
    fi

    # Validate the staged files whole before any of them land.
    bash -n "${staged_pins}"
    bash -n "${staged_sums}"
    (
        # shellcheck disable=SC1090,SC1091
        source "${dir}/lib/mod.sh"
        # shellcheck disable=SC1090
        source "${staged_sums}"
        # shellcheck disable=SC1090
        source "${staged_pins}"
        glowcap_devcontainer_validate_pins
    )
    # pins.sh lands last, so everything a version implies is already in place
    # when the version itself arrives. An interrupted bump leaves inert future
    # hashes and companion files one step ahead of the pin, which env-sync.sh
    # reports; the reverse would be a version whose hash and Dockerfiles still
    # name the old release.
    glowcap_pins_install "${staged_sums}" "${dir}/checksums.sh"
    local companion relative staged
    for companion in "${glowcap_pins_staged_companions[@]}"; do
        IFS=$'\t' read -r relative staged <<< "${companion}"
        glowcap_pins_install "${staged}" "$(glowcap_pins_companion_source "${relative}")"
    done
    glowcap_pins_install "${staged_pins}" "${dir}/pins.sh"

    echo
    echo "pins updated: ${changed}"
    echo "rebuild to adopt (bash .devcontainer/bin/up.sh --rebuild), then:"
    printf '%s' "${gates}" | sort -u
}

# ---------------------------------------------------------------------------

case "${1:-check}" in
    check) run_check ;;
    bump)
        shift
        [[ $# -gt 0 ]] || {
            usage >&2
            exit 2
        }
        if [[ "$1" == --safe ]]; then
            safe_deps=()
            for dep in ${GLOWCAP_PINS_DEPS}; do
                [[ "$(glowcap_pins_dep_class "${dep}")" == safe ]] && safe_deps+=("${dep}")
            done
            run_bump "${safe_deps[@]}"
        else
            for dep in "$@"; do glowcap_pins_dep_var "${dep}" >/dev/null || exit 2; done
            run_bump "$@"
        fi
        ;;
    -h | --help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
