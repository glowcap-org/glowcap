// A bridge's operator gateway, described by the bridge and drawn by Rooms.
//
// The operator side of a bridge is no more Rooms' to invent than the identity
// side is. IRC opens a connection with a host, a port, and optional SASL, and
// leases channels beneath it. Another bridge opens something else and leases
// something else, or leases nothing at all. So the bridge describes its
// gateway (the form to open a connection, the form to add a lease under one,
// the words for both, and the current connections and their leases) and Rooms
// draws it, the same split the identity form keeps.
//
// A connection groups leases the way an IRC network groups channels. A bridge
// with no such grouping declares a lease form that asks for nothing, and a
// bridge that leases nothing declares none. What a connection reaches, and
// what a lease is called, are the bridge's words, carried and not derived.

import * as z from "zod/mini";
import { type BridgeAnswers, type BridgeForm, BridgeFormSchema } from "./form.ts";
import {
	MAX_FORM_LABEL,
	MAX_FORM_SAID,
	MAX_FORM_TITLE,
	MAX_FORM_VALUE,
	MAX_GATEWAY_JSON,
	MAX_OPERATIONS_ROWS,
	MAX_ROOM,
} from "../limits.ts";
import { boundedText, nonemptyText } from "../schema.ts";

/** How a link state reads, in three tones Rooms styles: a settled good state,
 * a state in flight, and a failure. The bridge writes the word, and Rooms
 * paints the tone, as it does for the seat's link states. */
export const GatewayStatusSchema = z.strictObject({
	label: nonemptyText(MAX_FORM_LABEL),
	tone: z.enum(["ok", "pending", "failed", "idle"]),
});
export type GatewayStatus = z.infer<typeof GatewayStatusSchema>;

/** One line of a connection's own description: a labeled value the bridge
 * states about the connection, such as its endpoint or its login. */
export const GatewayFactSchema = z.strictObject({
	label: nonemptyText(MAX_FORM_LABEL),
	value: nonemptyText(MAX_FORM_VALUE),
});

/** How long a connection or a lease may be named. Ids and the titles that
 * usually restate them share this bound, and a bridge holds a user-authored
 * name to it at admission, so a retained connection can never describe itself
 * as something a snapshot then refuses to parse. An IRC channel name is legal
 * well past a Rooms room name's length, which is why this is wider than
 * `MAX_ROOM`. */
export const MAX_GATEWAY_NAME = 128;

/** One bridged resource under a connection: an IRC channel, or whatever the
 * bridge leases. `roomName` is the Rooms room it became, when it has one. */
export const GatewayLeaseSchema = z.strictObject({
	id: nonemptyText(MAX_GATEWAY_NAME),
	title: nonemptyText(MAX_GATEWAY_NAME),
	status: GatewayStatusSchema,
	problem: boundedText(MAX_FORM_SAID),
	roomName: z.nullable(nonemptyText(MAX_ROOM)),
	/** The Rooms publication id of the room this lease became, when it has one.
	 * The room-moderation surface matches its own room against this to know it
	 * administers the lease behind it. Empty for a lease with no room yet.  status-allow: pending state or quoted runtime label */
	publicationId: boundedText(128),
});
export type GatewayLease = z.infer<typeof GatewayLeaseSchema>;

/** One live connection the operator retains, with the leases under it. */
export const GatewayConnectionSchema = z.strictObject({
	id: nonemptyText(MAX_GATEWAY_NAME),
	title: nonemptyText(MAX_GATEWAY_NAME),
	facts: z.array(GatewayFactSchema).check(z.maxLength(8)),
	status: GatewayStatusSchema,
	problem: boundedText(MAX_FORM_SAID),
	leases: z.array(GatewayLeaseSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});
export type GatewayConnection = z.infer<typeof GatewayConnectionSchema>;

/** The act that removes one lease, in the bridge's words. Rooms draws the
 * button and the second step, and the bridge words them, because only the
 * bridge knows what removing a lease costs. `say` is the whole loss sentence,
 * `keep` the way out, and `commit` the commitment, the same three the identity
 * form's `confirm` carries. */
export const GatewayLeaseRemovalSchema = z.strictObject({
	label: nonemptyText(MAX_FORM_LABEL),
	say: nonemptyText(MAX_FORM_SAID),
	keep: nonemptyText(MAX_FORM_LABEL),
	commit: nonemptyText(MAX_FORM_LABEL),
});

/** The gateway as its bridge describes it right now. */
export const BridgeGatewaySchema = z.strictObject({
	/** What this gateway is and does, in the bridge's words, for the page head. */
	title: nonemptyText(MAX_FORM_TITLE),
	description: boundedText(MAX_FORM_SAID),
	/** The bridge's words for a connection and a lease, singular and plural,
	 * so the page says "network"/"channel" for IRC and whatever another bridge
	 * calls its own. */
	connectionNoun: nonemptyText(MAX_FORM_LABEL),
	connectionNounPlural: nonemptyText(MAX_FORM_LABEL),
	leaseNoun: nonemptyText(MAX_FORM_LABEL),
	leaseNounPlural: nonemptyText(MAX_FORM_LABEL),
	/** How removing one lease is worded, since only the bridge knows the cost. */
	leaseRemoval: GatewayLeaseRemovalSchema,
	/** Fill this to open a connection. Fill a lease form to add a lease. Both
	 * are ordinary bridge forms, drawn and split the way an identity form is. */
	connectionForm: BridgeFormSchema,
	leaseForm: BridgeFormSchema,
	connections: z.array(GatewayConnectionSchema).check(z.maxLength(MAX_OPERATIONS_ROWS)),
});
export type BridgeGateway = z.infer<typeof BridgeGatewaySchema>;

/** Parse a gateway description as it arrives on the wire: one JSON string,
 * bounded and checked before anything is built from it, as an identity form
 * is. */
export function parseBridgeGateway(raw: unknown): BridgeGateway {
	if (typeof raw !== "string" || raw === "") throw new Error("the bridge gateway answered no description");
	if (raw.length > MAX_GATEWAY_JSON) throw new Error("the bridge gateway answered too long a description");
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error("the bridge gateway answered a description that is not JSON");
	}
	const parsed = z.safeParse(BridgeGatewaySchema, decoded);
	if (!parsed.success) throw new Error("the bridge gateway answered an invalid description");
	return parsed.data;
}

export type { BridgeAnswers, BridgeForm };

// The gateway wire verbs, generic to any bridge. A gateway answers `snapshot`
// with its description and `openConnection` with a fresh connection. A
// connection capability answers `addLease`, `removeLease`, and `close`. The
// bridge decides what those forms ask for.
export const OPEN_CONNECTION = "openConnection";
export const GATEWAY_CONNECTION = "connection";
export const ADD_LEASE = "addLease";
export const REMOVE_LEASE = "removeLease";
export const CLOSE_CONNECTION = "closeConnection";
