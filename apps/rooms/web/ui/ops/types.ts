// The operations-capability vocabulary: which capabilities the page can hold,
// what each one's possession rows look like, and where a remembered swiss is
// keyed. Its own file beside the panes that draw it; `types.ts` re-exports it,
// so a consumer of the page vocabulary still has one import surface.

import type { DirId } from "../types.ts";

import type {
	DiagnosticRow,
	ListenerRow,
	OperatorCategory,
	OperatorLinkRow,
	OperatorReferenceKind,
	OperatorReferenceRow,
	OperatorRegistrationRow,
	OperatorRoomRow,
	OperatorSessionRow,
	OperatorTroubleRow,
	StewardshipRow,
} from "../../../lib/room/client.ts";
import type { BridgeGateway } from "../../../lib/bridge/gateway.ts";

/** One named object the inspect capability reported on this directory. */
export type { DiagnosticRow } from "../../../lib/room/client.ts";
export type { OperatorCategory } from "../../../lib/room/client.ts";
export type { OperatorReferenceRow } from "../../../lib/room/client.ts";

/** One live listener the admin capability reported on this directory. */
export type { ListenerRow } from "../../../lib/room/client.ts";

/** The operations capabilities the page knows how to hold. Holdings keeps one
 * toggle per capability; the Operations page draws one pane per held one.
 * The order here is the tab order when more than one is held. */
export { OPERATIONS_CAPABILITIES as OPS_CAPS, type OperationsCapability as OpsCap } from "../application_data.ts";
import { OPERATIONS_CAPABILITIES as OPS_CAPS } from "../application_data.ts";

/** One durable room this tab published into this directory while it holds the
 * peering capability. The lease behind the row lives in the data layer; what
 * the pane needs is the words and where the publication stands. */
export interface PeeringPublication {
	/** The row's handle for revoking, minted by the data layer. */
	id: string | number;
	/** The name the destination lists the room under. */
	name: string;
	/** The directory the room actually lives on, as the address this tab used. */
	source: string;
	/** Publishing is in flight, live at the destination, or being revoked. A
	 * failed publish leaves no row; its reason lands in the form that asked. */
	phase: "publishing" | "live" | "revoking" | "failed";
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

/** What this session knows about timeline publishing while it holds the
 * viz capability: where it publishes, whether the socket is up, and the
 * endpoint's sentence when that swiss is dead. Unlike its two siblings this
 * capability is presented to the timeline endpoint rather than fetched on the
 * directory session, so it survives a directory reconnect and dies only by
 * the reader's drop or the endpoint's refusal. */
export interface VizPublishState {
	/** The endpoint this session publishes to: Settings' URL, or the page's own. */
	readonly url: string;
	/** Whether the publish socket is connected. False while it redials, and
	 * after a refusal — `refusal` is how those two differ. */
	readonly connected: boolean;
	/** Why the endpoint refused this swiss. A refusal is final; it is not a redial. */
	readonly refusal: string | null;
}

/** What this tab holds while the IRC gateway capability is in hand: the
 * gateway's whole description, as the bridge behind it drew it. Possession is
 * this being non-null, the same rule as its siblings. It is a generic bridge
 * gateway; IRC is the one bridge that fills it today. */
export type IrcGatewayState = BridgeGateway;

/** One bridged room a room operator administers: the connection and lease it
 * belongs to, so the room's moderation surface can retire it, plus the room's
 * own publication so it can match itself against the gateway's leases. */
export interface AdministeredBridge {
	readonly connectionId: string;
	readonly leaseId: string;
	readonly publicationId: string;
}

/** One stewardship as the operator pane can act on. The server answers a
 * swiss; the data layer composes its copyable sturdyref with this directory's
 * actual route before it reaches the store. */
export interface StewardshipView extends Omit<StewardshipRow, "steward"> {
	readonly stewardLink: string | null;
}

export interface RoomsOperatorState {
	readonly revision: bigint;
	readonly stewardships: readonly StewardshipView[];
	readonly links: readonly OperatorLinkRow[];
	readonly registrations: readonly OperatorRegistrationRow[];
	readonly sessions: readonly OperatorSessionRow[];
	readonly rooms: readonly OperatorRoomRow[];
	readonly references: readonly OperatorReferenceRow[];
	readonly trouble: readonly OperatorTroubleRow[];
	readonly next: Readonly<Record<OperatorCategory, number | null>>;
	/** How many rows each inventory holds that match the search in force. The
	 * row arrays above are one page of that; a directory holding a hundred
	 * thousand references sends thirty-two of them. */
	readonly totals: Readonly<Record<OperatorCategory, number>>;
	/** The search these rows and totals answer, empty when the pane is showing
	 * the whole directory. */
	readonly search: string;
	/** An exact retained-reference subtype filter, independent of free text. */
	readonly referenceKind: OperatorReferenceKind | null;
}

/** Where a remembered operations swiss was redeemed: a directory for the
 * session-fetched capabilities, the endpoint URL for the visualizer. */
export type OpsScope = DirId | string;

/** Which operations capabilities this tab holds now.
 *
 * Never stored: possession's one authority is whether each capability's rows
 * are in the store, which the data layer sets on take and clears on drop or
 * reconnect. The Holdings toggles, the Operations control, and the modal's
 * panes are all derived from this, so none of them can disagree with the
 * capability actually being in hand. */
export interface OpsHeld {
	readonly listeners: boolean;
	readonly diagnostics: boolean;
	readonly irc: boolean;
	readonly operator: boolean;
	readonly peering: boolean;
	readonly viz: boolean;
}

/** Derive possession from the four row fields. */
export function opsHeldOf(
	listeners: readonly ListenerRow[] | null,
	diagnostics: readonly DiagnosticRow[] | null,
	irc: IrcGatewayState | null,
	operator: RoomsOperatorState | null,
	peering: PeeringState | null,
	viz: VizPublishState | null,
): OpsHeld {
	return {
		listeners: listeners !== null,
		diagnostics: diagnostics !== null,
		irc: irc !== null,
		operator: operator !== null,
		peering: peering !== null,
		viz: viz !== null,
	};
}

/** Whether any operations capability is held, which is what makes the
 * Operations control appear. One reader for the head, the modal, and App. */
export function anyOpsHeld(held: OpsHeld): boolean {
	return OPS_CAPS.some((cap) => held[cap]);
}
