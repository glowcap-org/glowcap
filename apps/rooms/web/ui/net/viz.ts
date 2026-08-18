// The tab's hand on the live timeline: publishing is a capability it holds,
// not a side effect of being configured.
//
// The endpoint admits no socket without its swiss, so a tab that only knows
// the URL publishes nothing. Like inspect and listeners next door, the swiss
// is taken through the Advanced toggle and possession is what the store row
// says — but this capability is presented to the timeline endpoint rather
// than fetched on the directory session, so it survives a directory
// reconnect and ends only with the reader's drop, or with the endpoint
// refusing the swiss (a restart that minted a fresh one). A refusal is a
// dead secret and erases what was remembered, the same contract as a failed
// auto-redeem of the other two.
//
// Arming installs the trace tap, so sessions opened from that moment appear
// on the timeline. A remembered swiss arms before the page's first host
// exists (`ensureVizPublisher`, called ahead of the wasm init), which is what
// puts the very first directory session on the timeline after a reload; a
// take from the toggle arms mid-life and the timeline starts at that moment.

import { enableTrace } from "@pancake/runtime";
import { publishViz, type VizPublisher } from "../../../lib/viz_publish.ts";
import { pastedSwiss } from "../../../lib/operations.ts";
import * as store from "../store.ts";
import * as prefs from "../prefs.ts";
import { reason } from "./common.ts";
import { forgetOpsSwiss, rememberedOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";

/** How long a take waits for the endpoint's answer. Refusal and admission
 * are both one round trip (the endpoint closes or sends its admission mark
 * immediately), so expiry means the endpoint is not answering at all. */
const TAKE_DEADLINE_MS = 8_000;

/** The publisher this tab armed, while it holds the capability. The swiss
 * stays inside the socket URL; the store row carries only what to draw. */
let held: { url: string; publisher: VizPublisher; uninstall: () => void } | null = null;

// The address bar's `?viz=` override, read once like the DM transport beside
// it: the tap's endpoint is decided when the peer opens, not mid-session.
const VIZ_OVERRIDE = prefs.vizOverride();

/** The endpoint this tab would publish to: the saved or `?viz=` override
 * (edited in the Visualizer pane once the capability is held), or the page's
 * own server's `/viz` answer, or null when there is none. */
async function vizEndpoint(): Promise<string | null> {
	if (VIZ_OVERRIDE !== null) return VIZ_OVERRIDE;
	return await prefs.advertisedViz();
}

/** Arm the publisher with `swiss` and install the trace tap. `onAdmitted`
 * hears the endpoint's admission mark; `onRefused` hears its typed refusal,
 * whenever either arrives — the drop and the erased memory have already
 * happened when a refusal does. */
function arm(
	url: string,
	swiss: string,
	hooks: { onAdmitted?: () => void; onRefused: (why: string) => void },
): void {
	const publisher: VizPublisher = publishViz(url, {
		cap: swiss,
		onError: (err) => console.error("rooms: viz publish error:", reason(err)),
		onStatus: (connected) => {
			if (held?.publisher !== publisher) return;
			store.setVizPublish({ url, connected });
			if (connected) hooks.onAdmitted?.();
		},
		onRefused: (why) => {
			if (held?.publisher !== publisher) return;
			dropVizCap();
			console.error("rooms: the timeline endpoint refused this tab's capability:", why);
			hooks.onRefused(why);
		},
	});
	held = { url, publisher, uninstall: enableTrace(publisher.sink) };
	store.setVizPublish({ url, connected: false });
}

/** The reader's drop, from the Advanced toggle: stop publishing, uninstall
 * the tap, and erase the remembered swiss — no path may drop the capability
 * but keep the secret the reader asked to give up. Also the refusal path's
 * cleanup, where the erased memory is a dead secret rather than a choice. */
export function dropVizCap(): void {
	if (held === null) return;
	const { url, publisher, uninstall } = held;
	held = null;
	publisher.stop();
	uninstall();
	store.setVizPublish(null);
	forgetOpsSwiss("viz", url);
}

/** Take the viz capability: present the pasted swiss (or a pasted
 * `ROOMS-VIZ-LISTENING` sturdyref, whose swissnum is the same secret) to the
 * endpoint this page publishes to. Returns an empty string when the tab now
 * holds it, or the reason it would not take. */
export async function takeVizCap(pasted: string, remember = false): Promise<string> {
	const url = await vizEndpoint();
	if (url === null) {
		return "This page has no live timeline endpoint. Start the server with --viz, or open the page with ?viz=<ws url>.";
	}
	const swiss = pastedSwiss(pasted);
	if (swiss === "") return "paste the swiss number the server printed";
	if (held !== null) dropVizCap();
	const outcome = await new Promise<string>((resolve) => {
		let settled = false;
		const settle = (why: string) => {
			if (settled) return;
			settled = true;
			clearTimeout(expiry);
			resolve(why);
		};
		const expiry = setTimeout(
			() => settle("The timeline endpoint did not answer. Check the visualizer URL and the server."),
			TAKE_DEADLINE_MS,
		);
		arm(url, swiss, {
			onAdmitted: () => settle(""),
			onRefused: (why) => settle(why),
		});
	});
	if (outcome !== "") {
		// A take that failed holds nothing: the refusal path already dropped,
		// and an unanswered endpoint must not keep redialing as if granted.
		dropVizCap();
		return outcome;
	}
	// The checkbox is the reader's current word on remembering, so an
	// unchecked take erases an earlier memory rather than leaving it to
	// auto-redeem against their answer.
	if (remember) rememberOpsSwiss("viz", url, pasted);
	else forgetOpsSwiss("viz", url);
	return "";
}

/** Arm publishing from what this browser remembered, before the page's first
 * host exists so its very first session open is captured. A page with no
 * endpoint, or no remembered swiss, installs no tap and pays one null check;
 * a remembered swiss the endpoint refuses is erased by the refusal path. */
export async function ensureVizPublisher(): Promise<void> {
	if (held !== null) return;
	const url = await vizEndpoint();
	if (url === null) return;
	const swiss = rememberedOpsSwiss("viz", url);
	if (swiss === null) return;
	if (held !== null) return;
	arm(url, pastedSwiss(swiss), { onRefused: () => {} });
}
