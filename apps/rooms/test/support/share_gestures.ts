// What a person does around a share from the page's saved source: starting
// it, the gestures its card and rows offer, and the source losing its
// connection.
import { described, type HeldControl } from "../../web/ui/session/managed/held_control.ts";
import { assert } from "../assert.ts";
import { noCeilings } from "./managed_link.ts";
import { offered as pageOffers, type ShareGesture } from "./share_offers.ts";
import { refused } from "./held_access_gestures.ts";
import type { Page } from "./held_access_page.ts";

/** Start the share every share table row starts from. */
export async function prepareShare(f: Page): Promise<void> {
	const held = f.sourceRow();
	assert(described(held), "the source is described");
	await f.management.prepareIssue(held, ["observeWorkspace"], "shared", false, 0, noCeilings);
}
/** The new access the share holds. */
export function made(f: Page): HeldControl {
	const control = f.management.issued;
	assert(control != null, "the share holds its new access");
	return control;
}
/** Make the source lose its own connection, as a call through it would. */
export async function loseSource(f: Page): Promise<void> {
	if (f.sourceRow().state.kind !== "reached") return;
	f.plan.sourceLost = true;
	await refused(() => f.management.refresh(f.sourceRow()));
	f.plan.sourceLost = false;
	// The loss a read outside a turn saw is kept in a turn of its own.
	await f.moved();
}

/** What a person can press on the page, as the page offers it. */
export const gestures: Record<ShareGesture, (f: Page) => Promise<unknown>> = {
	"press": (f) => f.management.goOnIssue(),
	"finish": (f) => f.management.discardIssue(),
	"save": (f) => f.management.save(made(f)),
	"remove the new access": (f) => f.management.forget(made(f)),
	"remove the source": (f) => f.management.forget(f.sourceRow()),
	"Try now on the source": (f) => f.management.reachAgain(f.sourceRow()),
	"Try now on the new access": (f) => f.management.reachAgain(made(f)),
};
/** The gestures the page offers now. */
export function offers(f: Page): ShareGesture[] {
	return pageOffers(f.management);
}
