// The operator's hand on a directory's listeners, taken as a capability.
//
// Like inspect, the listeners object is a second Host publication under an
// unguessable name (`--admin-listeners`), and holding that name is the whole
// of the authority. Taking it is the shared operations flow in
// `operations.ts`; what it answers — the listener rows, `up`, and `down` — is
// what this module owns. The server side lives in `server/listeners.ts`.

import type { Ref, Session } from "@pancake/runtime";
import { DOWN, LIST, UP } from "./protocol.ts";
import { ask } from "./ask.ts";
import { takeOperationsCap } from "./operations.ts";

/** One transport seat, as the admin capability reports it: the server's own
 * catalog entry (name, description, an optional reference page, what an `up`
 * may carry) plus its live state. The set is the server's to name, so an
 * operator surface renders whatever arrives instead of keeping a copy.
 * `serving` marks the listener whose locator the server announced — the one
 * the web relay dials, and the one `down` refuses to take. A standing
 * `unavailable` sentence means the server already knows an `up` would
 * refuse. */
/** One knob a seat's `up` accepts, as the server lists it. */
export interface ListenerUpOption {
	name: string;
	kind: "host" | "port" | "url";
	hint: string;
}

export interface ListenerRow {
	transport: string;
	description: string;
	/** A page that explains the technology, or empty. */
	reference: string;
	/** What the reference explains, as link text; empty exactly when
	 * `reference` is. */
	referenceName: string;
	/** The knobs this seat's `up` accepts: name, value shape, and what a
	 * blank field means in the server's own words. */
	takes: readonly ListenerUpOption[];
	/** Why an `up` would refuse today, or empty. */
	unavailable: string;
	/** The live listener's number, or null while down. */
	id: number | null;
	/** The live listener's dialable locator, or null while down. */
	locator: string | null;
	serving: boolean;
}

function parseRows(raw: unknown): ListenerRow[] {
	if (!Array.isArray(raw)) throw new Error("the listeners capability did not answer a list");
	const rows: ListenerRow[] = [];
	for (const row of raw) {
		const parsed = parseRow(row);
		if (parsed !== null) rows.push(parsed);
	}
	return rows;
}

function parseTakes(raw: unknown): readonly ListenerUpOption[] | null {
	if (!Array.isArray(raw)) return null;
	const takes: ListenerUpOption[] = [];
	for (const entry of raw) {
		if (!Array.isArray(entry) || entry.length < 3) return null;
		const [name, kind, hint] = entry;
		if (typeof name !== "string" || typeof hint !== "string") return null;
		if (kind !== "host" && kind !== "port" && kind !== "url") return null;
		takes.push({ name, kind, hint });
	}
	return takes;
}

function parseRow(row: unknown): ListenerRow | null {
	if (!Array.isArray(row) || row.length < 9) return null;
	const [transport, description, reference, referenceName, rawTakes, unavailable, id, locator, serving] = row;
	if (
		typeof transport !== "string" || typeof description !== "string" ||
		typeof reference !== "string" || typeof referenceName !== "string" ||
		typeof unavailable !== "string" ||
		typeof id !== "number" || typeof locator !== "string"
	) return null;
	const takes = parseTakes(rawTakes);
	if (takes === null) return null;
	return {
		transport,
		description,
		reference,
		referenceName,
		takes,
		unavailable,
		id: id === 0 ? null : id,
		locator: locator === "" ? null : locator,
		serving: serving === true,
	};
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
	return parseRows(await ask(session, cap, LIST, [], "the listeners capability did not answer"));
}

/** Bring a listener up on `transport` (a name the server's own list
 * answered), with values for whichever of the seat's declared knobs the
 * caller sets; the rest fall to the server's own defaults. Answers the
 * transport's refreshed seat. */
export async function listenerUp(
	session: Session,
	cap: Ref,
	transport: string,
	options?: Record<string, string | number>,
): Promise<ListenerRow> {
	const pairs = Object.entries(options ?? {});
	const args = pairs.length === 0 ? [transport] : [transport, pairs];
	const raw = await ask(session, cap, UP, args, `the listeners capability did not bring up ${transport}`);
	const row = parseRow(raw);
	if (row === null) throw new Error("the listeners capability answered up without a listener row");
	return row;
}

/** Take the listener numbered `id` down. It stops admitting connections;
 * sessions it already accepted stay live. */
export async function listenerDown(session: Session, cap: Ref, id: number): Promise<void> {
	await ask(session, cap, DOWN, [id], `the listeners capability did not take listener ${id} down`);
}
