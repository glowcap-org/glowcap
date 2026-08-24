// The operations-capability vocabulary: which capabilities the page can hold,
// what each one's possession rows look like, and where a remembered swiss is
// keyed. Its own file beside the panes that draw it; `types.ts` re-exports it,
// so a consumer of the page vocabulary still has one import surface.

import type { DirId } from "../types.ts";

import type { DiagnosticRow, IrcGatewayRow, ListenerRow } from "../../../lib/room_client.ts";

/** One named object the inspect capability reported on this directory. */
export type { DiagnosticRow } from "../../../lib/room_client.ts";

/** One live listener the admin capability reported on this directory. */
export type { ListenerRow } from "../../../lib/room_client.ts";

/** The operations capabilities the page knows how to hold. Advanced keeps one
 * toggle per capability; the Operations page draws one pane per held one.
 * The order here is the tab order when more than one is held. */
export const OPS_CAPS = ["listeners", "diagnostics", "irc", "peering", "viz"] as const;
export type OpsCap = (typeof OPS_CAPS)[number];

/** One durable room this tab published into this directory while it holds the
 * peering capability. The lease behind the row lives in the data layer; what
 * the pane needs is the words and where the publication stands. */
export interface PeeringPublication {
	/** The row's handle for revoking, minted by the data layer. */
	id: number;
	/** The name the destination lists the room under. */
	name: string;
	/** The directory the room actually lives on, as the address this tab used. */
	source: string;
	/** Publishing is in flight, live at the destination, or being revoked. A
	 * failed publish leaves no row; its reason lands in the form that asked. */
	phase: "publishing" | "live" | "revoking";
}

/** What this tab holds while the peering capability is in hand: the durable
 * rooms it has published here, oldest first. Possession is this row being
 * non-null, the same rule as its three siblings. */
export interface PeeringState {
	readonly publications: readonly PeeringPublication[];
}

/** One room this tab could publish into this directory: a room it has joined
 * on some other directory it also holds. Derived from the conversations, so
 * the pane's choices are exactly what the tab can actually reach. */
export interface PeeringSource {
	/** The conversation to publish, which is how the verb names it. */
	key: string;
	/** The room's name on its own directory, which prefills the published name. */
	room: string;
	/** The source directory, in the words the rail uses for it. */
	directory: string;
}

/** What this tab knows about its own timeline publishing while it holds the
 * viz capability: where it publishes, and whether the socket is up right now.
 * Unlike its two siblings this capability is presented to the timeline
 * endpoint rather than fetched on the directory session, so it survives a
 * directory reconnect and dies only by the reader's drop or the endpoint's
 * refusal. */
export interface VizPublishState {
	/** The endpoint this tab publishes to: Settings' URL, or the page's own. */
	readonly url: string;
	/** Whether the publish socket is connected; false while it redials. */
	readonly connected: boolean;
}

/** One IRC channel the gateway currently bridges into this directory: the
 * gateway's own row, aliased so the pane and the wire cannot drift. */
export type IrcBridgeRow = IrcGatewayRow;

/** What this tab holds while the IRC gateway capability is in hand: the
 * bridged channels as the gateway last listed them. Possession is this row
 * being non-null, the same rule as its siblings. */
export interface IrcGatewayState {
	readonly bridged: readonly IrcBridgeRow[];
}

/** Where a remembered operations swiss was redeemed: a directory for the
 * session-fetched capabilities, the endpoint URL for the visualizer. */
export type OpsScope = DirId | string;

/** Where `cap`'s swiss for `home` is kept in this browser.
 *
 * The name of a remembered fact is vocabulary, so it is here rather than with
 * the reading and writing of it in `net/ops_memory.ts`: a proof that seeds one
 * of these rows has to seed the row the page will actually look up, and this
 * module imports nothing at runtime, so it can say what that row is called
 * without starting a page. A row under a key nothing reads is silent — the tab
 * arms nothing, goes on working, and the failure surfaces somewhere else
 * entirely — which is worth one export to make impossible. */
export function opsSwissKey(cap: OpsCap, home: OpsScope): string {
	return `rooms.ops-swiss.${cap}.${home}`;
}

/** Which operations capabilities this tab holds now.
 *
 * Never stored: possession's one authority is whether each capability's rows
 * are in the store, which the data layer sets on take and clears on drop or
 * reconnect. The Capabilities toggles, the Operations control, and the modal's
 * panes are all derived from this, so none of them can disagree with the
 * capability actually being in hand. */
export interface OpsHeld {
	readonly listeners: boolean;
	readonly diagnostics: boolean;
	readonly irc: boolean;
	readonly peering: boolean;
	readonly viz: boolean;
}

/** Derive possession from the four row fields. */
export function opsHeldOf(
	listeners: readonly ListenerRow[] | null,
	diagnostics: readonly DiagnosticRow[] | null,
	irc: IrcGatewayState | null,
	peering: PeeringState | null,
	viz: VizPublishState | null,
): OpsHeld {
	return {
		listeners: listeners !== null,
		diagnostics: diagnostics !== null,
		irc: irc !== null,
		peering: peering !== null,
		viz: viz !== null,
	};
}

/** Whether any operations capability is held, which is what makes the
 * Operations control appear. One reader for the head, the modal, and App. */
export function anyOpsHeld(held: OpsHeld): boolean {
	return OPS_CAPS.some((cap) => held[cap]);
}
