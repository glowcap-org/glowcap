// The inspect capability: what this directory holds, to a holder that can look
// and not touch.
//
// Its own file because it is its own subject. The directory's behavior answers
// the peers using it; this answers one operator-minted capability about the
// directory itself, and the two share nothing but the tables they read.

import type { Argument, Behavior } from "@pancake/runtime";
import { currentSession, type Session } from "@pancake/runtime";
import { hasCapabilityArguments } from "../lib/argument_custody.ts";
import { DIRECTORY, SNAPSHOT } from "../lib/protocol.ts";
import type { RoomServerContext } from "./context.ts";
import { refuseDirectoryCall } from "./directory_behavior.ts";
import { linkFace } from "./operator/inventory.ts";
import { stewardshipRows } from "./operator/stewardships.ts";
import { RoomLinks } from "./room_links.ts";
import type { RoomServerSessions } from "./sessions.ts";

/** What the inspect capability can currently see of this directory.
 *
 * Rows are `[kind, name, note]`, and the kinds cover the same inventories the
 * operator acts on: `directory`, `room`, `occupant`, `registration`, `link`,
 * `session`, `moderator`, and `trouble`.
 *
 * The line between the two capabilities is what a row is made of, not which
 * inventories each may look at. Inspect sees that a thing exists; the handle
 * that would let somebody change it stays with the operator. So a link is
 * listed without its swiss, a moderated room without its moderator
 * capability, and a session without the id the operator's disconnect takes.
 * Each of those is dropped at exactly one place, right where the operator's
 * own row builder handed it over, so a field added to one of those builders
 * arrives here as a field this function never reads rather than as a leak.
 *
 * Live room references are not handed out here either: holding inspect is the
 * right to *see* what the directory holds, and entering a room is still
 * `enter` / `open` on the directory the caller already fetched.
 *
 * Retained references are the one inventory missing. Walking them mints the
 * operator's own release handles as it goes, so reading them from here would
 * advance that identifier sequence from a capability that can never use one.
 * Closing it means separating the traversal from the minting in
 * `OperatorReferenceInventory`, which is a change to the operator's inventory
 * and belongs with it.
 *
 * This is the Rooms operator's own view, so it shows every room including
 * private ones, by label and with their occupants. That is not the leak a
 * private room is protected from: privacy here is being absent from the
 * user-facing `list` and `watch`, unreachable except through a reference
 * somebody handed you. The operator, who holds the `--diagnostics` swiss and
 * runs the process, is the one principal that view was never hiding from. */
function diagnosticSnapshot(
	ctx: RoomServerContext,
	links: RoomLinks | null,
	sessions: RoomServerSessions,
	session: Session,
): Argument[] {
	const rows: Argument[] = [[
		"directory",
		DIRECTORY,
		"published bootstrap",
	]];
	for (const state of ctx.live.rooms.values()) {
		const place = state.policy.visibility === "secret" ? "private" : "listed";
		rows.push([
			"room",
			state.name,
			`${place}, ${state.members.length} here`,
		]);
		for (const member of state.members) {
			rows.push(["occupant", member.nick, `in ${state.name}`]);
		}
	}
	for (const intro of ctx.live.introductions.values()) {
		rows.push([
			"registration",
			intro.nick,
			`${intro.inboxes.size} inboxes offered`,
		]);
	}
	if (links !== null) {
		for (const { name } of links.named()) {
			// Inspect observes that the durable publication exists. Its swiss is
			// bearer authority to enter the room and belongs only on a separately
			// granted recovery/control surface, so `named()` is read for its name
			// alone. The name is resolved the operator's own way, or the two pages
			// would call one room by two different words.
			const face = linkFace(ctx, links, name);
			rows.push([
				"link",
				face.label || face.name,
				`${face.visibility}, durable publication active`,
			]);
		}
		// Every room this server can issue a moderator capability for, from the
		// operator's own row builder rather than a second walk that would drift
		// from it: an unissued room is a row on the operator's page too, and
		// dropping it here would have inspect report a shorter inventory than
		// the operator reads from the same source. The same rule as a link
		// applies to what a row carries: whether a capability is out is what
		// inspect sees, and the capability itself never enters a row.
		for (const row of stewardshipRows(ctx, links, session)) {
			rows.push([
				"moderator",
				row.label || row.name,
				row.issued ? "moderator capability issued" : "no moderator capability issued",
			]);
		}
	}
	// Peer sessions, by what carries them. The operator's own row source, minus
	// the id: that id is the handle its Disconnect verb takes, and inspect has
	// no verb to take one.
	for (const source of sessions.operatorFaces(session)) {
		const { transport, nick } = source.build();
		rows.push(["session", transport, nick === "" ? "no registered nickname" : `registered as ${nick}`]);
	}
	// The server's own trouble journal rides the same snapshot, so an operator
	// holding inspect reads what went wrong beside what the directory holds.
	for (const entry of ctx.journal.rows()) {
		rows.push([
			"trouble",
			entry.source,
			entry.count > 1 ? `${entry.reason} ×${entry.count}` : entry.reason,
		]);
	}
	return rows;
}

export function inspectBehavior(
	ctx: RoomServerContext,
	sessions: RoomServerSessions,
	links: RoomLinks | null = null,
): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session == null) throw new Error("diagnostics is reachable only over a session");
		if (hasCapabilityArguments(args)) {
			refuseDirectoryCall(session, args, new Error(`diagnostics ${verb} does not take capability arguments`));
		}
		if (verb === SNAPSHOT) {
			if (args.length !== 0) throw new Error("snapshot takes no arguments");
			return diagnosticSnapshot(ctx, links, sessions, session);
		}
		throw new Error(`diagnostics has no method ${verb}`);
	};
}
