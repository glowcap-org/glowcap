// Every access row a page can hold says only what it offers, and offers a way
// forward. The table walks every reachable combination of the control's state,
// its storage, its status, how it failed (unreached, or reached with a failed
// last read), and where a share stands with it. Each row offers at least one
// way forward, and its failure names Try now, Remove or Manage only where the
// row shows that button. A row's failure is said once: on the row's own line,
// which names the step after it, and never again by the Try now that met it.
import { assert } from "../assert.ts";
import { reachFailure } from "../support/browser_failure.ts";
import { fakeHandle } from "../support/managed_link.ts";
import { unreachedAccess } from "../../lib/text/managed_access.ts";
import type { LocalRefusalKey } from "../../lib/text/local_refusals.ts";
import { rowOffers, rowShows } from "../../web/ui/session/managed/access_row.ts";
import {
	type ControlState,
	described,
	type DescribedControl,
	type HeldControl,
	OWN_CONTROL,
	standingFailure,
	unreachedView,
} from "../../web/ui/session/managed/held_control.ts";
import type { PendingIssue } from "../../web/ui/session/managed/share_state.ts";
import type { RoomsManagedControl } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagementView } from "../../web/ui/session/managed/access_powers.ts";

/** Each way a control can fail to be reached: every code a row words in its
 * own way, and one it does not. */
const failures = [...unreachedAccess.keys(), "transport-not-dialed"];
const kinds: ControlState["kind"][] = ["reached", "unreached", "undescribed"];
const storages: HeldControl["storage"][] = [{ kind: "saved" }, { kind: "unsaved", address: null }];
/** What the page holds as the control's standing: active, paused, or revoked. */
const standings = ["active", "paused", "revoked"];
/** Where a share stands with this row's control. */
const shares = ["none", "from it", "made it", "elsewhere"];
const ids = ["row", OWN_CONTROL];

function control(
	id: string,
	kind: ControlState["kind"],
	code: string,
	standing: string,
	storage: HeldControl["storage"],
) {
	const failure = reachFailure("the reach's answer", code);
	const powers: ManagementView = {
		available: standing !== "revoked",
		status: standing === "paused" ? "paused" : "active",
		issueCeiling: { permissions: [], bounds: [] },
	};
	const state: ControlState = kind === "reached"
		? { kind, handle: fakeHandle<RoomsManagedControl>({}), grant: null, powers }
		: kind === "unreached"
		? { kind, failure, grant: null, powers }
		: { kind, failure };
	const held: HeldControl = { id, state, storage };
	// A reached control holds a failure only as its last read's.
	if (kind === "reached" && code !== "none") held.readFailure = failure;
	return held;
}
/** Another control the page holds, reached and described. */
function elsewhere(storage: HeldControl["storage"]): DescribedControl {
	const other = control("other", "reached", "none", "active", storage);
	if (!described(other)) throw new Error("a reached control is described");
	return other;
}

for (const id of ids) {
	for (const kind of kinds) {
		for (const storage of storages) {
			// The page's own control is always saved.
			if (id === OWN_CONTROL && storage.kind !== "saved") continue;
			for (const standing of standings) {
				for (const code of kind === "reached" ? ["none", ...failures] : failures) {
					// The page's own control is its own session's, which holds it over a
					// transport this page uses, so it never fails for good.
					if (
						id === OWN_CONTROL &&
						(code === "session-capability-gone" || code === "saved-transport-unavailable")
					) {
						continue;
					}
					for (const share of shares) {
						// A share comes from a described control and makes one not yet saved.
						if (share === "from it" && kind === "undescribed") continue;
						if (share === "made it" && (storage.kind === "saved" || id === OWN_CONTROL)) continue;
						const row = `${id} ${kind} ${storage.kind} ${standing} ${code}, share ${share}`;
						Deno.test(`an access row ${row} says only what it offers, and offers a way forward`, () => {
							const held = control(id, kind, code, standing, storage);
							const other = elsewhere(storage);
							const issue = share === "none" ? null : fakeHandle<PendingIssue>({
								phase: "committed",
								source: share === "from it" && described(held) ? held : other,
								made: { kind: "held", control: share === "made it" ? held : other },
							});
							const removal = (): LocalRefusalKey | null =>
								id === OWN_CONTROL
									? "access-own-stays-held"
									: share === "from it"
									? "access-share-source"
									: share === "made it"
									? "access-share-made-unsaved"
									: null;
							const offers = rowOffers({ issue, removal }, held);
							const removeHere = offers.remove && offers.manage == null;
							assert(
								offers.tryNow || offers.save || removeHere || offers.manage != null ||
									offers.share != null,
								`${row} offers a way forward`,
							);
							const said = offers.failure ?? "";
							assert(
								(code === "none") === (offers.failure == null),
								`${row} says why it is unreached or its read failed`,
							);
							// The Try now that met the row's failure leaves it to the row's line,
							// which names the step before trying again, and shows a failure the
							// row does not hold.
							const failure = standingFailure(held);
							const step = failure == null ? null : unreachedView(failure).action;
							assert(
								!offers.tryNow || (step != null && said.includes(step)),
								`${row} names the step before Try now`,
							);
							assert(
								!rowShows(held, reachFailure("another answer", code)),
								`${row} leaves a failure it does not hold to the press`,
							);
							const names = (word: string) => new RegExp(`\\b${word}\\b`, "i").test(said);
							assert(!names("remove") || offers.remove, `${row} names a Remove it offers`);
							assert(!names("manage") || offers.manage != null, `${row} names a Manage it shows`);
							assert(
								!names("remove") || names("manage") === (offers.manage != null),
								`${row} names where Remove is`,
							);
							assert(
								!/try again/i.test(said) || offers.tryNow,
								`${row} says to try again only with Try now`,
							);
							assert(
								offers.share?.kind !== "new" || kind === "reached",
								`${row} shares only from a reached source`,
							);
						});
					}
				}
			}
		}
	}
}
