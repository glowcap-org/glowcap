#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
spec="$repo_root/conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md"
netlayers="$repo_root/conformance/ocapn-spec/upstream/draft-specifications/Netlayers.md"
suite="$repo_root/conformance/ocapn-conformance/upstream/utils/captp_types.py"
goblins="$repo_root/conformance/spritely-goblins/upstream/goblins/ocapn/captp.rkt"
goblins_urls="$repo_root/conformance/spritely-goblins/upstream/goblins/ocapn/structs-urls.rkt"

submodules="conformance/ocapn-spec/upstream
conformance/ocapn-conformance/upstream
conformance/spritely-goblins/upstream"

# The finding is about specific revisions, so a checkout that is missing, or
# has drifted off the commit this repository pins, cannot answer it. `git
# submodule status` marks those with `-` and `+`; only a leading space is the
# pinned commit.
echo "$submodules" | while IFS= read -r path; do
    status=$(git -C "$repo_root" submodule status -- "$path")
    case "$status" in
    ' '*) ;;
    '-'*)
        printf '%s\n' "ocapn-findings-check: $path is not initialized — run conformance/bootstrap-submodules.sh" >&2
        exit 1
        ;;
    *)
        printf '%s\n' "ocapn-findings-check: $path has drifted off its pinned commit:$status" >&2
        printf '%s\n' "  restore it with: git submodule update --init -- $path" >&2
        printf '%s\n' "  or bump the pin and re-evaluate the finding against the new revision" >&2
        exit 1
        ;;
    esac
done

require_text() {
    path=$1
    text=$2
    label=$3
    if [ ! -f "$path" ]; then
        printf '%s\n' "ocapn-findings-check: $label source is missing at $path" >&2
        printf '%s\n' "  run: bash conformance/bootstrap-submodules.sh" >&2
        exit 1
    fi
    if ! grep -Fq -- "$text" "$path"; then
        printf '%s\n' "ocapn-findings-check: $label changed at $path" >&2
        exit 1
    fi
}

require_text "$spec" "<op:listen to-desc" "draft op:listen record"
require_text "$spec" "listen-desc>      ; desc:import-object | desc:import-promise" "draft two-operand op:listen tail"
require_text "$suite" "assert len(record.args) == 3" "suite op:listen arity"
require_text "$suite" "wants_partial = record.args[2]" "suite third op:listen operand"
require_text "$goblins" "(to-desc listener-desc wants-partial?)" "Goblins third op:listen operand"
require_text "$netlayers" "Since hints is just a mapping of information" "draft mapping-shaped locator hints"
require_text "$goblins_urls" "[hints (or/c #f string?)]" "Goblins string-or-false locator hints"
require_text "$goblins_urls" "ignoring hints" "Goblins hints-ignoring node equality"
require_text "$goblins" "($ locations->open-session-names 'ref exporter-location))" "Goblins withdrawal session lookup by full node value"
require_text "$goblins" "($ locations->open-session-names 'set remote-location session-name)" "Goblins session registration under the hello-declared location"

printf '%s\n' "ocapn-findings-check: pinned op:listen, locator-hints, and withdrawal-lookup discrepancies reproduced"
git -C "$repo_root" submodule status -- $submodules
