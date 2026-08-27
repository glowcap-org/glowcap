// The Rooms application operator: actionable inventory across server owners.
//
// A room steward and the Rooms operator are deliberately different objects.
// The steward can moderate one room; the operator can inventory, issue, and
// revoke those authorities, but performs no moderation verb itself. This is a
// boot capability beside listeners, diagnostics, IRC, peering, and viz—not a
// method on the public directory and not a rank inferred from membership.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@pancake/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../../lib/argument_custody.ts";
import { NO_SUCH_ROOM, NOT_STEWARD, RoomError } from "../../lib/errors.ts";
import {
	isPrivateRoomKey,
	MAX_DURABLE_ROOM,
	MAX_OPERATOR_PAGE,
	MAX_OPERATOR_QUERY,
	MAX_OPERATOR_RETIRE_BATCH,
} from "../../lib/limits.ts";
import {
	CLEAR_OPERATOR_TROUBLE,
	DISCONNECT_SESSION,
	GIVE_STEWARD,
	isOperatorCategory,
	OPERATOR_CATEGORIES,
	OPERATOR_RETIRE_MATCHING,
	OPERATOR_SNAPSHOT,
	OPERATOR_UNWATCH,
	OPERATOR_WATCH,
	RELEASE_OPERATOR_REFERENCE,
	REMOVE_OPERATOR_ROOM,
	RESET_OPERATOR_SCOPE,
	REVOKE_NICK,
	REVOKE_ROOM_LINK,
	REVOKE_STEWARD,
} from "../../lib/protocol.ts";
import { introductions } from "../registry.ts";
import type { RoomLinks } from "../room_links.ts";
import { revokeIntroduction } from "../introductions.ts";
import { clearTrouble } from "../journal.ts";
import { removeOperatorRoom, resetOperatorRooms } from "./rooms.ts";
import { releaseOperatorReference } from "./references.ts";
import { operatorFaces } from "./inventory.ts";
import { queryBatch, queryPage } from "./page.ts";
import { liveRoom, type StewardshipRow, wireStewardshipRow } from "./stewardships.ts";
import { dropOperatorWatcher, holdOperatorNotices, operatorRevision, watchOperator } from "./revision.ts";
import { disconnectAllOperatorSessions, disconnectOperatorSession, sessionByOperatorId } from "../sessions.ts";

function refuseOperatorCall(session: Session, args: readonly Argument[], message: string): never {
	throwAfterReleasingCapabilities(session, args, new Error(message));
}

function operatorSnapshotPage(links: RoomLinks, session: Session, args: Argument[]): Argument {
	if (
		args.length < 3 || args.length > 4 || typeof args[0] !== "string" || typeof args[1] !== "bigint" ||
		typeof args[2] !== "bigint" || (args.length === 4 && typeof args[3] !== "string")
	) {
		throw new Error("operatorSnapshot takes a category, cursor, limit, and optional query");
	}
	if (
		args[1] < 0n || args[1] > BigInt(Number.MAX_SAFE_INTEGER) || args[2] < 1n ||
		args[2] > BigInt(MAX_OPERATOR_PAGE)
	) throw new Error("operatorSnapshot cursor or limit is out of range");
	const category = args[0];
	if (!isOperatorCategory(category)) throw new Error("operatorSnapshot category is unknown");
	const query = args.length === 4 ? (args[3] as string) : "";
	if (query.length > MAX_OPERATOR_QUERY) throw new Error("operatorSnapshot query is too long");
	const page = queryPage(operatorFaces(links, session, category), query, Number(args[1]), Number(args[2]));
	const rows = page.rows.map((row) => row.wire());
	return [
		operatorRevision(),
		page.more ? BigInt(Number(args[1]) + rows.length) : null,
		rows,
		BigInt(page.total),
	] as Argument;
}

/** Retire every row of one inventory that matches a search, in bounded
 * batches: the answer says how many this call retired and how many still
 * match, and the caller runs again for the rest. Bounded because one call
 * must not hold the turn while a hundred thousand rows are retired, and
 * because an operator watching a count fall has to be able to stop. */
async function operatorRetireMatching(links: RoomLinks, session: Session, args: Argument[]): Promise<Argument> {
	if (
		args.length !== 3 || typeof args[0] !== "string" || typeof args[1] !== "string" || typeof args[2] !== "bigint"
	) {
		throw new Error("operatorRetireMatching takes a category, a query, and a batch limit");
	}
	const category = args[0];
	if (!isOperatorCategory(category)) throw new Error("operatorRetireMatching category is unknown");
	if (args[1].length > MAX_OPERATOR_QUERY) throw new Error("operatorRetireMatching query is too long");
	if (args[2] < 1n || args[2] > BigInt(MAX_OPERATOR_RETIRE_BATCH)) {
		throw new Error("operatorRetireMatching batch limit is out of range");
	}
	const query = args[1];
	const batch = queryBatch(operatorFaces(links, session, category), query, Number(args[2]));
	let retired = 0;
	let refused = "";
	await holdOperatorNotices(async () => {
		for (const row of batch.rows) {
			if (row.retire === null) continue;
			try {
				await row.retire();
				retired += 1;
			} catch (error) {
				// tolerant: one row that changed under the sweep must not abandon
				// the rest, and the first reason is what the operator is told.
				if (refused === "") refused = error instanceof Error ? error.message : String(error);
			}
		}
	});
	const left = queryBatch(operatorFaces(links, session, category), query, 0);
	return [BigInt(retired), BigInt(left.total), refused] as Argument;
}

function operatorSnapshotAll(links: RoomLinks, session: Session, query: string): Argument {
	const revision = operatorRevision();
	const pages = OPERATOR_CATEGORIES.map((category) => {
		const page = operatorSnapshotPage(links, session, [category, 0n, BigInt(MAX_OPERATOR_PAGE), query]);
		if (!Array.isArray(page) || page.length !== 4 || page[0] !== revision) {
			throw new Error("operator inventory changed during its synchronous snapshot");
		}
		return [category, page[1], page[2], page[3]];
	});
	return [revision, pages] as Argument;
}

function resetRegistrations(): void {
	for (const intro of [...introductions.values()]) revokeIntroduction(intro.nick, intro.registrar);
}

function resetSessions(caller: Session): void {
	disconnectAllOperatorSessions(caller);
}

async function retireRuntime(caller: Session): Promise<void> {
	await resetOperatorRooms();
	resetRegistrations();
	resetSessions(caller);
}

function namedRoom(links: RoomLinks, raw: Argument | undefined): string {
	const asked = typeof raw === "string" ? raw : "";
	if (asked.length === 0 || asked.length > MAX_DURABLE_ROOM) {
		throw new RoomError(NO_SUCH_ROOM, "stewardship needs a durable room name");
	}
	const live = liveRoom(asked);
	if (live !== null) return live.private ? live.key : live.name;
	const durable = links.named().find((row) => row.name.toLowerCase() === asked.toLowerCase());
	if (durable != null) return durable.name;
	throw new RoomError(NO_SUCH_ROOM, `this server owns no room named "${asked}"`);
}

function rowFor(links: RoomLinks, session: Session, name: string): StewardshipRow {
	const live = liveRoom(name);
	const isPrivate = live?.private ?? isPrivateRoomKey(name);
	const authority = links.stewardship(name, session);
	return {
		name,
		label: live?.name ?? (isPrivate ? "" : name),
		visibility: isPrivate ? "private" : "listed",
		generation: authority.generation,
		issued: authority.issued,
		steward: authority.steward,
	};
}

/** The separately published Rooms operator capability. */
export function roomsOperatorBehavior(links: RoomLinks): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session == null) throw new Error("the Rooms operator is reachable only over a session");
		if (verb !== OPERATOR_WATCH && hasCapabilityArguments(args)) {
			refuseOperatorCall(session, args, `Rooms operator ${verb} does not take capability arguments`);
		}
		if (verb === OPERATOR_SNAPSHOT) {
			if (args.length <= 1) {
				if (args.length === 1 && (typeof args[0] !== "string" || args[0].length > MAX_OPERATOR_QUERY)) {
					throw new Error("operatorSnapshot takes one optional search");
				}
				return operatorSnapshotAll(links, session, args.length === 1 ? args[0] as string : "");
			}
			return operatorSnapshotPage(links, session, args);
		}
		if (verb === OPERATOR_RETIRE_MATCHING) {
			return operatorRetireMatching(links, session, args) as ReturnType<Behavior>;
		}
		if (verb === OPERATOR_WATCH) {
			if (args.length !== 1 || !(args[0] instanceof Ref)) {
				refuseOperatorCall(session, args, "watch takes one callback capability");
			}
			return watchOperator(session, args[0]) as ReturnType<Behavior>;
		}
		if (verb === OPERATOR_UNWATCH) {
			if (args.length !== 0) throw new Error("unwatch takes no arguments");
			dropOperatorWatcher(session);
			return null;
		}
		if (verb === REVOKE_ROOM_LINK) {
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("revokeRoomLink takes one room name");
			return links.revokeRoomLink(args[0]).then(() => null) as ReturnType<Behavior>;
		}
		if (verb === REVOKE_NICK) {
			if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "string") {
				throw new Error("revokeNick takes a nickname and session id");
			}
			const target = sessionByOperatorId(args[1]);
			if (target === null || !revokeIntroduction(args[0], target)) throw new Error("that nickname claim changed");
			return null;
		}
		if (verb === DISCONNECT_SESSION) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("disconnectSession takes one session id");
			}
			if (!disconnectOperatorSession(args[0], session)) {
				throw new Error("that session is absent or is this operator");
			}
			return null;
		}
		if (verb === REMOVE_OPERATOR_ROOM) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("removeOperatorRoom takes one room id");
			}
			return removeOperatorRoom(args[0]).then((removed) => {
				if (!removed) throw new Error("that room generation is no longer present");
				return null;
			}) as ReturnType<Behavior>;
		}
		if (verb === RELEASE_OPERATOR_REFERENCE) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("releaseOperatorReference takes one reference id");
			}
			releaseOperatorReference(args[0]);
			return null;
		}
		if (verb === CLEAR_OPERATOR_TROUBLE) {
			if (args.length !== 0) throw new Error("clearOperatorTrouble takes no arguments");
			clearTrouble();
			return null;
		}
		if (verb === RESET_OPERATOR_SCOPE) {
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("resetOperatorScope takes one scope");
			if (args[0] === "links") {
				return Promise.all(links.named().map((row) => links.revokeRoomLink(row.name))).then(() =>
					null
				) as ReturnType<Behavior>;
			}
			if (args[0] === "registrations") {
				resetRegistrations();
				return null;
			}
			if (args[0] === "sessions") {
				resetSessions(session);
				return null;
			}
			if (args[0] === "rooms") {
				return resetOperatorRooms().then(() => null) as ReturnType<Behavior>;
			}
			if (args[0] === "runtime") {
				clearTrouble();
				return retireRuntime(session).then(() => null) as ReturnType<Behavior>;
			}
			if (args[0] === "all") {
				clearTrouble();
				return links.factoryReset().then(() => retireRuntime(session)).then(() => null) as ReturnType<Behavior>;
			}
			throw new Error("unknown operator reset scope");
		}
		if (verb === GIVE_STEWARD) {
			if (args.length !== 1) throw new Error("giveSteward takes one durable room name");
			const name = namedRoom(links, args[0]);
			return links.steward(name, session).then(() =>
				wireStewardshipRow(rowFor(links, session, name))
			) as ReturnType<
				Behavior
			>;
		}
		if (verb === REVOKE_STEWARD) {
			if (args.length !== 1) throw new Error("revokeSteward takes one durable room name");
			const name = namedRoom(links, args[0]);
			if (!links.hasSteward(name)) {
				throw new RoomError(NOT_STEWARD, `room "${name}" has no issued stewardship`);
			}
			return links.revokeSteward(name).then(() => wireStewardshipRow(rowFor(links, session, name))) as ReturnType<
				Behavior
			>;
		}
		throw new Error(`Rooms operator has no method ${verb}`);
	};
}
