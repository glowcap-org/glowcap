#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$repo_root/.devcontainer/pins.sh"
spec="$repo_root/conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md"
netlayers="$repo_root/conformance/ocapn-spec/upstream/draft-specifications/Netlayers.md"
suite="$repo_root/conformance/ocapn-conformance/upstream/utils/captp_types.py"
goblins="$repo_root/conformance/spritely-goblins/upstream/goblins/ocapn/captp.rkt"
goblins_urls="$repo_root/conformance/spritely-goblins/upstream/goblins/ocapn/structs-urls.rkt"
goblins_onion="$repo_root/conformance/spritely-goblins/upstream/goblins/ocapn/netlayer/onion.rkt"

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

goblins_revision=$(git -C "$repo_root/conformance/spritely-goblins/upstream" rev-parse HEAD)
if [ "$goblins_revision" != "$GOBLINS_REVISION" ]; then
    printf '%s\n' "ocapn-findings-check: devcontainer Goblins $GOBLINS_REVISION does not match submodule $goblins_revision" >&2
    printf '%s\n' "  update .devcontainer/pins.sh with the submodule so live checks run the source they report" >&2
    exit 1
fi

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
require_text "$spec" "listen-mode>      ; Postive integer (1, 2, or 3)" "draft integer op:listen mode"
require_text "$suite" "assert len(record.args) == 3" "suite op:listen arity"
require_text "$suite" "wants_partial = record.args[2]" "suite third op:listen operand"
require_text "$goblins" "(to-desc listener-desc wants-partial?)" "Goblins third op:listen operand"
require_text "$netlayers" "Since hints is just a mapping of information" "draft mapping-shaped locator hints"
require_text "$goblins_urls" "[hints (or/c #f string?)]" "Goblins string-or-false locator hints"
require_text "$goblins_urls" "ignoring hints" "Goblins hints-ignoring node equality"
require_text "$goblins" "($ locations->open-session-names 'ref exporter-location))" "Goblins withdrawal session lookup by full node value"
require_text "$goblins" "($ locations->open-session-names 'set remote-location session-name)" "Goblins session registration under the hello-declared location"
require_text "$spec" 'MUST not have been used in the **Exporter-Receiver** session' "draft Exporter-Receiver handoff-count scope"
require_text "$goblins" "($ gifter-exporter-session-coordinator 'get-remote-handoff-count)" "Goblins Gifter-Exporter handoff-count check"
require_text "$goblins" "($ gifter-exporter-session-coordinator 'new-handoff-count (add1 this-handoff-count))" "Goblins Gifter-Exporter handoff-count advance"
require_text "$spec" "when this is sent the connection should" "draft op:abort connection teardown"
require_text "$repo_root/conformance/ocapn-conformance/upstream/tests/op_abort.py" "with self.assertRaises((TimeoutError, ConnectionAbortedError)):" "suite pre-handshake abort outcomes"
require_text "$goblins" "(bcom (lambda _ (void)))" "Goblins pre-handshake abort handler"
require_text "$goblins_onion" "(<-np-extern conn-establisher read-message write-message #f)" "Goblins onion accept supplies no remote node"
require_text "$goblins_onion" "[(ocapn-node 'onion designator #f)" "Goblins onion dial matches only an unhinted locator"
require_text "$repo_root/conformance/ocapn-spec/upstream/draft-specifications/Locators.md" "the designator and transport are the only" "draft locator comparison ignores hints"
require_text "$goblins" "(? ocapn-node? claimed-remote-location)" "Goblins hello arm accepts any claimed node, hints included"
require_text "$goblins" "#;(unless (same-node-location? claimed-remote-location remote-location)" "Goblins hello location-mismatch check commented out"
require_text "$spec" "A bytearray containing 32 randomly generated bytes" "draft 32-byte gift id"
require_text "$repo_root/conformance/ocapn-conformance/upstream/tests/third_party_handoffs.py" 'def make_valid_handoff(self, gift_id=b"my-gift")' "suite seven-byte valid gift id"
require_text "$repo_root/conformance/ocapn-conformance/upstream/tests/third_party_handoffs.py" "may not exist if test fails early" "suite receiver-teardown hazard comment"
require_text "$repo_root/conformance/ocapn-conformance/upstream/tests/third_party_handoffs.py" "if self.e2r_session is not None:" "suite receiver-teardown unguarded attribute read"

printf '%s\n' "ocapn-findings-check: pinned op:listen mode, locator-hints, withdrawal-lookup, handoff-count, pre-handshake-abort, onion-declared-location, hello-hint-tolerance, gift-id-width, and receiver-teardown observations reproduced"
git -C "$repo_root" submodule status -- $submodules
