// The tab's hand on the live timeline: publishing is a capability it holds,
// not a side effect of being configured.
//
// The endpoint admits no socket without its swiss, so a tab that only knows
// the URL publishes nothing. Like inspect and listeners next door, the swiss
// is taken through the Capabilities toggle and possession is what the store row
// says — but this capability is presented to the timeline endpoint rather
// than fetched on the directory session, so it survives a directory
// reconnect and ends only with the reader's drop, or with the endpoint
// refusing the swiss (a restart that minted a fresh one). A refusal is a
// dead secret and erases what was remembered, the same contract as a failed
// auto-redeem of the other two.
//
// Arming installs the trace tap, so sessions opened from that moment appear
// on the timeline. A remembered local swiss arms after workspace restoration
// and before the first directory session, which puts that connection on the
// timeline after a reload. An attached workspace does not arm this tab: the
// durable session already publishes, and a second producer here would present
// the session's swiss at this page's door, treat a refusal as a dead secret,
// and toast as if this tab had been the one holding it. A take from the
// toggle arms a local tab mid-life; an attached take is refused.

import * as store from "../store.ts";
import { enableTrace, retainSecondaryFailure } from "@pancake/runtime";
import { publishViz, type VizPublisher } from "../../../lib/viz_publish.ts";
import { presentedSwiss } from "../../../lib/operations.ts";
import * as prefs from "../prefs.ts";
import { opsLost, trouble } from "./common.ts";
import { forgetOpsSwiss, rememberedOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import type { RoomsPageContext } from "../page.ts";

/** How long a take waits for the endpoint's answer. Refusal and admission
 * are both one round trip (the endpoint closes or sends its admission mark
 * immediately), so expiry means the endpoint is not answering at all. */
const TAKE_DEADLINE_MS = 8_000;

type ArmedViz = { url: string; publisher: VizPublisher; uninstall: () => void };

/** The publisher one page armed, while it holds the capability. */
export class PageViz {
	armed: ArmedViz | null = null;
}

function retireVizHold(
	page: RoomsPageContext,
	holding: ArmedViz,
	label: string,
): void {
	if (page.viz.armed === holding) page.viz.armed = null;
	let failure: unknown | null = null;
	try {
		holding.publisher.stop();
	} catch (error) {
		failure = error;
	}
	try {
		holding.uninstall();
	} catch (error) {
		failure = failure == null ? error : retainSecondaryFailure(failure, error);
	}
	store.setVizPublish(page.projection, null);
	if (failure != null) trouble(page.projection, label, failure);
}

function retireDeadViz(page: RoomsPageContext, url: string, label: string): void {
	if (!forgetOpsSwiss(page, "viz", url)) {
		store.noteTrouble(
			page.projection,
			"capability storage",
			"the dead visualizer capability could not be forgotten",
		);
	}
	const holding = page.viz.armed;
	if (holding?.url === url) retireVizHold(page, holding, label);
}

// The address bar's `?viz=` override, read once like the DM transport beside
// it: the tap's endpoint is decided when the peer opens, not mid-session.
function advertisedVizOverride() {
	return prefs.vizOverride();
}

/** The endpoint this tab would publish to: the saved or `?viz=` override
 * (edited in the Visualizer pane once the capability is held), or the page's
 * own server's `/viz` answer, or null when there is none. */
async function vizEndpoint(): Promise<string | null> {
	const override = advertisedVizOverride();
	if (override !== null) return override;
	return await prefs.advertisedViz();
}

export function vizCapabilityScope(): Promise<string | null> {
	return vizEndpoint();
}

/** Arm the publisher with `swiss` and install the trace tap. `onAdmitted`
 * hears the endpoint's admission mark; `onRefused` hears its typed refusal,
 * whenever either arrives — the drop and the erased memory have already
 * happened when a refusal does. */
function arm(
	page: RoomsPageContext,
	url: string,
	swiss: string,
	hooks: { onAdmitted?: () => void; onRefused: (why: string) => void },
): void {
	const publisher: VizPublisher = publishViz(url, {
		cap: swiss,
		onError: (err) => trouble(page.projection, "the visualizer publisher errored", err),
		onStatus: (connected) => {
			if (page.viz.armed?.publisher !== publisher) return;
			store.setVizPublish(page.projection, { url, connected, refusal: null });
			if (connected) hooks.onAdmitted?.();
		},
		onRefused: (why) => {
			if (page.viz.armed?.publisher !== publisher) return;
			retireDeadViz(page, url, "the refused visualizer publisher would not retire");
			hooks.onRefused(why);
		},
	});
	// Telemetry, not contents. The trace tap can forward each frame's bytes,
	// and this tab's frames include direct messages whose other end never
	// agreed to appear on a shared timeline. Room lines lose nothing by it:
	// the room server publishes the same frames from its own side, and the
	// endpoint folds the two sightings together on the frame digest, which is
	// carried whatever the payload cap. What still travels from here is who
	// this tab talked to, when, which verb, and how many bytes.
	let uninstall: () => void;
	try {
		uninstall = enableTrace(publisher.sink, { payloadCap: 0 });
	} catch (error) {
		try {
			publisher.stop();
		} catch (cleanup) {
			retainSecondaryFailure(error, cleanup);
		}
		throw error;
	}
	page.viz.armed = { url, publisher, uninstall };
	store.setVizPublish(page.projection, { url, connected: false, refusal: null });
}

/** The reader's drop, from the Capabilities toggle: stop publishing, uninstall
 * the tap, and erase the remembered swiss — no path may drop the capability
 * but keep the secret the reader asked to give up. Also the refusal path's
 * cleanup, where the erased memory is a dead secret rather than a choice. */
export function dropVizCap(page: RoomsPageContext, updateVault = true): void {
	const holding = page.viz.armed;
	if (holding == null) return;
	if (updateVault && !forgetOpsSwiss(page, "viz", holding.url)) {
		store.noteTrouble(
			page.projection,
			"capability storage",
			"the saved visualizer capability could not be removed",
		);
		return;
	}
	retireVizHold(page, holding, "the visualizer publisher would not retire");
}

function dropVizHoldOnly(page: RoomsPageContext, url: string): void {
	const holding = page.viz.armed;
	if (holding?.url !== url) return;
	retireVizHold(page, holding, "the unsaved visualizer publisher would not retire");
}

/** Whether this tab is the visualizer producer. A shared session already
 * publishes from the session process; this module must not arm a second
 * producer or treat that session's swiss as a secret this tab can forget. */
function tabPublishesViz(page: RoomsPageContext): boolean {
	return page.attachedSession.current == null;
}

/** Take the viz capability: present the pasted swiss (or a pasted
 * `ROOMS-VIZ-LISTENING` sturdyref, whose swissnum is the same secret) to the
 * endpoint this page publishes to. Returns an empty string when the tab now
 * holds it, or the reason it would not take. */
export async function takeVizCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	if (!tabPublishesViz(page)) {
		return "The shared session already publishes to the timeline. This tab does not take that capability.";
	}
	const url = await vizEndpoint();
	if (url === null) {
		return "This page has no live timeline endpoint. Start the server with --viz, or open the page with ?viz=<ws url>.";
	}
	const swiss = presentedSwiss(pasted);
	if (swiss === "") return "paste the swiss number the server printed";
	if (page.viz.armed !== null) {
		dropVizCap(page);
		if (page.viz.armed !== null) {
			return "The current visualizer capability could not be removed from browser storage.";
		}
	}
	const outcome = await new Promise<string>((resolve) => {
		let settled = false;
		// Whether this call is what answered the take, so a refusal arriving
		// after an admitted one — the endpoint restarting under a swiss it no
		// longer mints — is reported to the reader instead of resolving a
		// promise nobody is waiting on any more.
		const settle = (why: string): boolean => {
			if (settled) return false;
			settled = true;
			clearTimeout(expiry);
			resolve(why);
			return true;
		};
		const expiry = setTimeout(
			() => settle("The timeline endpoint did not answer. Check the visualizer URL and the server."),
			TAKE_DEADLINE_MS,
		);
		arm(page, url, swiss, {
			onAdmitted: () => settle(""),
			onRefused: (why) => {
				if (!settle(why)) opsLost(page.projection, "viz", why);
			},
		});
	});
	if (outcome !== "") {
		// A take that failed holds nothing: the refusal path already dropped,
		// and an unanswered endpoint must not keep redialing as if granted.
		retireDeadViz(page, url, "the unanswered visualizer publisher would not retire");
		return outcome;
	}
	// The checkbox is the reader's current word on remembering, so an
	// unchecked take erases an earlier memory rather than leaving it to
	// auto-redeem against their answer.
	const stored = remember ? rememberOpsSwiss(page, "viz", url, pasted) : forgetOpsSwiss(page, "viz", url);
	if (!stored) {
		dropVizHoldOnly(page, url);
		return "This browser refused to update the saved visualizer capability.";
	}
	return "";
}

/** Arm publishing from this tab's remembered visualizer swiss.
 *
 * Local only. The durable session already publishes for an attached workspace,
 * so this is a no-op while that session is held. A page with no endpoint, or
 * no remembered swiss, installs no tap. A remembered swiss the endpoint refuses
 * is erased by the refusal path. */
export async function ensureVizPublisher(page: RoomsPageContext): Promise<void> {
	if (!tabPublishesViz(page)) return;
	if (page.viz.armed !== null) return;
	const url = await vizEndpoint();
	if (url === null) return;
	const swiss = rememberedOpsSwiss(page, "viz", url);
	if (swiss === null) return;
	if (page.viz.armed !== null) return;
	// Nobody is waiting on this arm, so its refusal has no return path: a
	// restarted endpoint minting a fresh swiss would otherwise turn the toggle
	// off with no word for a capability the reader had asked to keep.
	arm(page, url, presentedSwiss(swiss), { onRefused: (why) => opsLost(page.projection, "viz", why) });
}
