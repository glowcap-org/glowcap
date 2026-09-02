// The operator's hand on a directory's listeners, taken as a capability.
//
// Like inspect, the listeners object is a second Host publication under an
// unguessable name (`--admin-listeners`), and holding that name is the whole
// of the authority. Taking it is the shared operations flow in
// `operations.ts`; what it answers — the listener rows, `up`, and `down` — is
// what this module owns. The server side lives in `server/listeners.ts`.

import type { Ref, Session } from "@glowcap/runtime";
import {
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_ONION,
	TRANSPORT_TCP,
} from "@glowcap/runtime";
import * as z from "zod/mini";
import { LIST } from "./protocol.ts";
import { DOWN, UP } from "./protocol_operator.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";
import { MAX_OPERATIONS_ROWS } from "./limits.ts";
import { boundedText, nonemptyText, positiveSafeInteger } from "./schema.ts";

export const LISTENER_TRANSPORTS = [
	TRANSPORT_TCP,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_ONION,
] as const;
export const ListenerTransportSchema = z.enum(LISTENER_TRANSPORTS);
export type ListenerTransport = z.infer<typeof ListenerTransportSchema>;
export type ListenerOptionName = "bind" | "port" | "advertise" | "relay";
export const LISTENER_OPTION_NAMES: Record<ListenerTransport, readonly ListenerOptionName[]> = {
	[TRANSPORT_TCP]: ["bind", "port", "advertise"],
	[TRANSPORT_KEYED_TCP]: ["bind", "port", "advertise"],
	[TRANSPORT_NOISE_TCP]: ["bind", "port", "advertise"],
	[TRANSPORT_IROH]: [],
	[TRANSPORT_KEYED_RELAY]: ["relay"],
	[TRANSPORT_NOISE_RELAY]: ["relay"],
	[TRANSPORT_ONION]: [],
};

const listenerText = boundedText(64 * 1024);
const listenerOptionKind = z.enum(["host", "port", "url"]);
const listenerTakes = z.array(z.tuple([listenerText, listenerOptionKind, listenerText])).check(z.maxLength(32));

/** One knob a seat's `up` accepts, as the server lists it. */
export const ListenerUpOptionSchema = z.strictObject({
	name: listenerText,
	kind: listenerOptionKind,
	hint: listenerText,
});

export type ListenerUpOption = z.infer<typeof ListenerUpOptionSchema>;

export const ListenerOptionsSchema = z.record(
	nonemptyText(64),
	z.union([boundedText(64 * 1024), z.int()]),
).check(z.refine((options) => Object.keys(options).length <= 16));

export type ListenerOptions = z.infer<typeof ListenerOptionsSchema>;

export function listenerOptionsFitTransport(transport: ListenerTransport, options: ListenerOptions): boolean {
	const allowed = new Set<string>(LISTENER_OPTION_NAMES[transport]);
	return Object.keys(options).every((name) => allowed.has(name));
}

/** One transport seat, as the admin capability reports it: the server's own
 * catalog entry (name, description, an optional reference page, what an `up`
 * may carry) plus its live state. The set is the server's to name, so an
 * operator surface renders whatever arrives instead of keeping a copy.
 * `serving` marks the listener whose locator the server announced — the one
 * the web relay dials, and the one `down` refuses to take. A standing
 * `unavailable` sentence means the server already knows an `up` would
 * refuse. */

export const ListenerRowSchema = z.strictObject({
	transport: listenerText,
	description: listenerText,
	/** A page that explains the technology, or empty. */
	reference: listenerText,
	/** What the reference explains, as link text; empty exactly when
	 * `reference` is. */
	referenceName: listenerText,
	/** The knobs this seat's `up` accepts: name, value shape, and what a
	 * blank field means in the server's own words. */
	takes: z.array(ListenerUpOptionSchema).check(z.maxLength(32)),
	/** Why an `up` would refuse today, or empty. */
	unavailable: listenerText,
	/** The live listener's number, or null while down. */
	id: z.nullable(positiveSafeInteger),
	/** The live listener's dialable locator, or null while down. */
	locator: z.nullable(listenerText),
	serving: z.boolean(),
}).check(
	z.refine((row) =>
		(row.id == null) === (row.locator == null) && (!row.serving || row.id != null) &&
		(row.reference === "") === (row.referenceName === "")
	),
);

export type ListenerRow = z.infer<typeof ListenerRowSchema>;

const ListenerWireRowSchema = z.tuple([
	listenerText,
	listenerText,
	listenerText,
	listenerText,
	listenerTakes,
	listenerText,
	z.int().check(z.gte(0)),
	listenerText,
	z.boolean(),
]).check(
	z.refine((row) =>
		(row[6] === 0) === (row[7] === "") && (!row[8] || row[6] > 0) &&
		(row[2] === "") === (row[3] === "")
	),
);
const ListenerWireRowsSchema = z.array(ListenerWireRowSchema).check(z.maxLength(MAX_OPERATIONS_ROWS));

function adaptListenerRow(row: z.infer<typeof ListenerWireRowSchema>): ListenerRow {
	const [transport, description, reference, referenceName, rawTakes, unavailable, id, locator, serving] = row;
	return {
		transport,
		description,
		reference,
		referenceName,
		takes: rawTakes.map(([name, kind, hint]) => ({ name, kind, hint })),
		unavailable,
		id: id === 0 ? null : id,
		locator: locator === "" ? null : locator,
		serving,
	};
}

export function parseListenerRows(raw: unknown): ListenerRow[] {
	const parsed = z.safeParse(ListenerWireRowsSchema, raw);
	if (!parsed.success) throw new Error("the listeners capability answered an invalid snapshot");
	return parsed.data.map(adaptListenerRow);
}

function parseListenerRow(raw: unknown): ListenerRow {
	const parsed = z.safeParse(ListenerWireRowSchema, raw);
	if (!parsed.success) throw new Error("the listeners capability answered an invalid row");
	return adaptListenerRow(parsed.data);
}

/** Fetch the listeners object and ask it for the live listeners. */
export async function takeListeners(session: Session, pasted: string): Promise<{
	cap: Ref;
	rows: ListenerRow[];
}> {
	const { cap, taken } = await takeOperationsCap(session, pasted, (fetched) => listListeners(session, fetched));
	return { cap, rows: taken };
}

/** Ask a listeners capability already in hand for the live listeners. */
export async function listListeners(session: Session, cap: Ref): Promise<ListenerRow[]> {
	return parseListenerRows(await ask(session, cap, LIST, [], "the listeners capability did not answer"));
}

/** Bring a listener up on `transport` (a name the server's own list
 * answered), with values for whichever of the seat's declared knobs the
 * caller sets; the rest fall to the server's own defaults. Answers the
 * transport's refreshed seat. */
export async function listenerUp(
	session: Session,
	cap: Ref,
	transport: string,
	options?: ListenerOptions,
): Promise<ListenerRow> {
	const pairs = Object.entries(options ?? {});
	const args = pairs.length === 0 ? [transport] : [transport, pairs];
	const raw = await ask(session, cap, UP, args, `the listeners capability did not bring up ${transport}`);
	return parseListenerRow(raw);
}

/** Take the listener numbered `id` down. It stops admitting connections;
 * sessions it already accepted stay live. */
export async function listenerDown(session: Session, cap: Ref, id: number): Promise<void> {
	await ask(session, cap, DOWN, [id], `the listeners capability did not take listener ${id} down`);
}
