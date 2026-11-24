// What the page offers a person around a share, read through the functions
// its card and rows render from.
import type { ManagedAccess } from "../../web/ui/session/managed/access.ts";
import { rowOffers } from "../../web/ui/session/managed/access_row.ts";
import type { HeldControl } from "../../web/ui/session/managed/held_control.ts";
import { cardAction } from "../../web/ui/session/managed/share_state.ts";
import { closeFinishes } from "../../web/ui/session/managed/access_card.ts";

/** A gesture around a share, as the tables name it. */
export type ShareGesture =
	| "press"
	| "finish"
	| "save"
	| "remove the new access"
	| "remove the source"
	| "Try now on the source"
	| "Try now on the new access";
/** Every gesture around a share, in the order the tables name them. Its type
 * holds it to every gesture and no other. */
const named: Record<ShareGesture, null> = {
	"press": null,
	"finish": null,
	"save": null,
	"remove the new access": null,
	"remove the source": null,
	"Try now on the source": null,
	"Try now on the new access": null,
};
const isGesture = (name: string): name is ShareGesture => Object.hasOwn(named, name);
export const shareGestures: readonly ShareGesture[] = Object.keys(named).filter(isGesture);

/** The gestures `management` offers around its share. */
export function offered(management: ManagedAccess): ShareGesture[] {
	const issue = management.issue;
	if (issue == null) return [];
	const row = (control: HeldControl | null) => control == null ? null : rowOffers(management, control);
	const source = row(issue.source);
	const access = row(management.issued);
	const card = cardAction(issue, issue.source);
	const offers: ShareGesture[] = [];
	const finishes = card.kind === "done" || card.kind === "review";
	if (!finishes && card.ready) offers.push("press");
	// Closing the card also lets go of a share that sent nothing.
	if (finishes || closeFinishes(issue, false)) offers.push("finish");
	if (access?.save === true) offers.push("save");
	if (access?.remove === true) offers.push("remove the new access");
	if (source?.remove === true) offers.push("remove the source");
	if (source?.tryNow === true) offers.push("Try now on the source");
	if (access?.tryNow === true) offers.push("Try now on the new access");
	return offers;
}
