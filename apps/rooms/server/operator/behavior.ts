// The Rooms application operator: actionable inventory across server owners.
//
// A room steward and the Rooms operator are deliberately different objects.
// The steward can moderate one room; the operator can inventory, issue, and
// revoke those authorities, but performs no moderation verb itself. This is a
// boot capability beside listeners, diagnostics, IRC, peering, and viz—not a
// method on the public directory and not a rank inferred from membership.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@glowcap/runtime";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../../lib/argument_custody.ts";
import { NO_SUCH_ROOM, NOT_STEWARD, RoomError } from "../../lib/errors.ts";
import {
	MAX_DURABLE_ROOM,
	MAX_OPERATOR_PAGE,
	MAX_OPERATOR_QUERY,
	MAX_OPERATOR_RETIRE_BATCH,
} from "../../lib/limits.ts";
import {
	CLEAR_OPERATOR_TROUBLE,
	DISCONNECT_SESSION,
	GIVE_MANAGER,
	GIVE_STEWARD,
	OPERATOR_RETIRE_MATCHING,
	OPERATOR_SNAPSHOT,
	OPERATOR_UNWATCH,
	OPERATOR_WATCH,
	RELEASE_OPERATOR_REFERENCE,
	REMOVE_OPERATOR_ROOM,
	RESET_OPERATOR_SCOPE,
	REVOKE_NICK,
	REVOKE_ROOM_AUTHORITY,
	REVOKE_ROOM_LINK,
	REVOKE_STEWARD,
} from "../../lib/protocol_operator.ts";
import {
	isOperatorCategory,
	isOperatorReferenceKind,
	OPERATOR_CATEGORIES,
	type OperatorReferenceKind,
} from "../../lib/operator_vocabulary.ts";
import type { RoomServerContext } from "../context.ts";
import type { RoomLinks } from "../room_links.ts";
import { revokeIntroduction } from "../introductions.ts";
import { removeOperatorRoom, resetOperatorRooms } from "./rooms.ts";
import { OperatorReferenceInventory } from "./references.ts";
import { operatorFaces } from "./inventory.ts";
import { queryBatch, queryPage } from "./page.ts";
import { liveRoom, type StewardshipRow, wireStewardshipRow } from "./stewardships.ts";
import type { RoomServerSessions } from "../sessions.ts";
import type { IrcBridgeAuthorities } from "../irc_gateway/authority.ts";

function refuseOperatorCall(session: Session, args: readonly Argument[], message: string): never {
	throwAfterReleasingCapabilities(session, args, new Error(message));
}

function operatorSnapshotPage(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	sessions: RoomServerSessions,
	references: OperatorReferenceInventory,
	bridges: IrcBridgeAuthorities | null,
	args: Argument[],
): Argument {
	if (
		args.length < 3 || args.length > 5 || typeof args[0] !== "string" || typeof args[1] !== "bigint" ||
		typeof args[2] !== "bigint" || (args.length >= 4 && typeof args[3] !== "string")
	) {
		throw new Error(
			"operatorSnapshot takes a category, cursor, limit, optional query, and optional reference kind",
		);
	}
	if (
		args[1] < 0n || args[1] > BigInt(Number.MAX_SAFE_INTEGER) || args[2] < 1n ||
		args[2] > BigInt(MAX_OPERATOR_PAGE)
	) throw new Error("operatorSnapshot cursor or limit is out of range");
	const category = args[0];
	if (!isOperatorCategory(category)) throw new Error("operatorSnapshot category is unknown");
	const query = args.length >= 4 ? (args[3] as string) : "";
	const referenceKind = args.length === 5 && isOperatorReferenceKind(args[4]) ? args[4] : null;
	if (args.length === 5 && (referenceKind === null || category !== "references")) {
		throw new Error("operatorSnapshot reference kind is invalid for this category");
	}
	if (query.length > MAX_OPERATOR_QUERY) throw new Error("operatorSnapshot query is too long");
	if (category === "references") references.resetSweep(session);
	const page = queryPage(
		operatorFaces(ctx, links, session, sessions, references, category, referenceKind, bridges),
		query,
		Number(args[1]),
		Number(args[2]),
	);
	const rows = page.rows.map((row) => row.wire());
	return [
		ctx.operator.current,
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
async function operatorRetireMatching(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	sessions: RoomServerSessions,
	references: OperatorReferenceInventory,
	bridges: IrcBridgeAuthorities | null,
	args: Argument[],
): Promise<Argument> {
	if (
		(args.length !== 3 && args.length !== 4) || typeof args[0] !== "string" || typeof args[1] !== "string" ||
		typeof args[2] !== "bigint"
	) {
		throw new Error("operatorRetireMatching takes a category, query, batch limit, and optional reference kind");
	}
	const category = args[0];
	if (!isOperatorCategory(category)) throw new Error("operatorRetireMatching category is unknown");
	if (args[1].length > MAX_OPERATOR_QUERY) throw new Error("operatorRetireMatching query is too long");
	if (args[2] < 1n || args[2] > BigInt(MAX_OPERATOR_RETIRE_BATCH)) {
		throw new Error("operatorRetireMatching batch limit is out of range");
	}
	const query = args[1];
	const referenceKind = args.length === 4 && isOperatorReferenceKind(args[3]) ? args[3] : null;
	if (args.length === 4 && (referenceKind === null || category !== "references")) {
		throw new Error("operatorRetireMatching reference kind is invalid for this category");
	}
	if (category === "references") {
		const answer = await ctx.operator.holdNotices(() =>
			Promise.resolve(references.retireMatching(session, query, referenceKind, Number(args[2])))
		);
		return [BigInt(answer.retired), BigInt(answer.remaining), answer.refused] as Argument;
	}
	const batch = queryBatch(
		operatorFaces(ctx, links, session, sessions, references, category, referenceKind, bridges),
		query,
		Number(args[2]),
	);
	let retired = 0;
	let refused = "";
	await ctx.operator.holdNotices(async () => {
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
	const left = queryBatch(
		operatorFaces(ctx, links, session, sessions, references, category, referenceKind, bridges),
		query,
		0,
	);
	return [BigInt(retired), BigInt(left.total), refused] as Argument;
}

function operatorSnapshotAll(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	sessions: RoomServerSessions,
	references: OperatorReferenceInventory,
	bridges: IrcBridgeAuthorities | null,
	query: string,
	referenceKind: OperatorReferenceKind | null,
): Argument {
	const revision = ctx.operator.current;
	const pages = OPERATOR_CATEGORIES.map((category) => {
		const page = operatorSnapshotPage(ctx, links, session, sessions, references, bridges, [
			category,
			0n,
			BigInt(MAX_OPERATOR_PAGE),
			query,
			...(category === "references" && referenceKind !== null ? [referenceKind] : []),
		]);
		if (!Array.isArray(page) || page.length !== 4 || page[0] !== revision) {
			throw new Error("operator inventory changed during its synchronous snapshot");
		}
		return [category, page[1], page[2], page[3]];
	});
	return [revision, pages] as Argument;
}

function resetRegistrations(ctx: RoomServerContext): void {
	for (const intro of [...ctx.live.introductions.values()]) revokeIntroduction(ctx, intro.nick, intro.registrar);
}

function resetSessions(sessions: RoomServerSessions, caller: Session): void {
	sessions.disconnectAll(caller);
}

async function retireRuntime(ctx: RoomServerContext, sessions: RoomServerSessions, caller: Session): Promise<void> {
	await resetOperatorRooms(ctx);
	resetRegistrations(ctx);
	resetSessions(sessions, caller);
}

function namedRoom(ctx: RoomServerContext, links: RoomLinks, raw: Argument | undefined): string {
	const asked = typeof raw === "string" ? raw : "";
	if (asked.length === 0 || asked.length > MAX_DURABLE_ROOM) {
		throw new RoomError(NO_SUCH_ROOM, "A moderator capability needs a durable room name.");
	}
	const live = liveRoom(ctx, asked);
	if (live !== null) return live.key;
	const durable = links.named().find((row) => row.name.toLowerCase() === asked.toLowerCase());
	if (durable != null) return durable.name;
	throw new RoomError(NO_SUCH_ROOM, `This server owns no room named "${asked}".`);
}

function rowFor(ctx: RoomServerContext, links: RoomLinks, session: Session, name: string): StewardshipRow {
	const live = liveRoom(ctx, name);
	const managed = links.managedRoom(name);
	const isPrivate = live?.policy.visibility === "secret" || managed?.policy.visibility === "secret";
	const authority = links.stewardship(name, session);
	return {
		name,
		label: live?.name ?? managed?.name ?? (isPrivate ? "" : name),
		visibility: isPrivate ? "private" : "listed",
		generation: authority.generation,
		issued: authority.issued,
		steward: authority.steward,
	};
}

/** The separately published Rooms operator capability. */
export function roomsOperatorBehavior(
	ctx: RoomServerContext,
	links: RoomLinks,
	sessions: RoomServerSessions,
	bridges: IrcBridgeAuthorities | null = null,
): Behavior {
	const references = new OperatorReferenceInventory(ctx);
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session == null) throw new Error("the Rooms operator is reachable only over a session");
		if (verb !== OPERATOR_WATCH && hasCapabilityArguments(args)) {
			refuseOperatorCall(session, args, `Rooms operator ${verb} does not take capability arguments`);
		}
		if (verb === OPERATOR_SNAPSHOT) {
			if (args.length <= 2) {
				if (args.length >= 1 && (typeof args[0] !== "string" || args[0].length > MAX_OPERATOR_QUERY)) {
					throw new Error("operatorSnapshot takes one optional search");
				}
				const referenceKind = args.length === 2 && isOperatorReferenceKind(args[1]) ? args[1] : null;
				if (args.length === 2 && (typeof args[0] !== "string" || referenceKind === null)) {
					throw new Error("operatorSnapshot reference kind is invalid");
				}
				return operatorSnapshotAll(
					ctx,
					links,
					session,
					sessions,
					references,
					bridges,
					args.length >= 1 ? args[0] as string : "",
					referenceKind,
				);
			}
			return operatorSnapshotPage(ctx, links, session, sessions, references, bridges, args);
		}
		if (verb === OPERATOR_RETIRE_MATCHING) {
			return operatorRetireMatching(ctx, links, session, sessions, references, bridges, args) as ReturnType<
				Behavior
			>;
		}
		if (verb === OPERATOR_WATCH) {
			if (args.length !== 1 || !(args[0] instanceof Ref)) {
				refuseOperatorCall(session, args, "watch takes one callback capability");
			}
			return ctx.operator.watch(session, args[0]) as ReturnType<Behavior>;
		}
		if (verb === OPERATOR_UNWATCH) {
			if (args.length !== 0) throw new Error("unwatch takes no arguments");
			ctx.operator.dropWatcher(session);
			return null;
		}
		if (verb === REVOKE_ROOM_LINK) {
			if (args.length !== 1 || typeof args[0] !== "string") throw new Error("revokeRoomLink takes one room name");
			return links.revokeRoomLink(namedRoom(ctx, links, args[0])).then(() => null) as ReturnType<Behavior>;
		}
		if (verb === REVOKE_ROOM_AUTHORITY) {
			if (
				args.length !== 2 || (args[0] !== "room" && args[0] !== "steward" && args[0] !== "manager") ||
				typeof args[1] !== "string"
			) {
				throw new Error("revokeRoomAuthority takes a room authority kind and publication token");
			}
			return links.revokeAuthority(args[0], args[1]).then(() => null) as ReturnType<Behavior>;
		}
		if (verb === REVOKE_NICK) {
			if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "string") {
				throw new Error("revokeNick takes a nickname and session id");
			}
			const target = sessions.byOperatorId(args[1]);
			if (target === null || !revokeIntroduction(ctx, args[0], target)) {
				throw new Error("that nickname claim changed");
			}
			return null;
		}
		if (verb === DISCONNECT_SESSION) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("disconnectSession takes one session id");
			}
			if (!sessions.disconnect(args[0], session)) {
				throw new Error("that session is absent or is this operator");
			}
			return null;
		}
		if (verb === REMOVE_OPERATOR_ROOM) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("removeOperatorRoom takes one room id");
			}
			return removeOperatorRoom(ctx, args[0]).then((removed) => {
				if (!removed) throw new Error("that room generation is no longer present");
				return null;
			}) as ReturnType<Behavior>;
		}
		if (verb === RELEASE_OPERATOR_REFERENCE) {
			if (args.length !== 1 || typeof args[0] !== "string") {
				throw new Error("releaseOperatorReference takes one reference id");
			}
			references.release(args[0]);
			return null;
		}
		if (verb === CLEAR_OPERATOR_TROUBLE) {
			if (args.length !== 0) throw new Error("clearOperatorTrouble takes no arguments");
			ctx.journal.clear();
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
				resetRegistrations(ctx);
				return null;
			}
			if (args[0] === "sessions") {
				resetSessions(sessions, session);
				return null;
			}
			if (args[0] === "rooms") {
				return resetOperatorRooms(ctx).then(() => null) as ReturnType<Behavior>;
			}
			if (args[0] === "runtime") {
				ctx.journal.clear();
				return retireRuntime(ctx, sessions, session).then(() => null) as ReturnType<Behavior>;
			}
			if (args[0] === "all") {
				ctx.journal.clear();
				return links.factoryReset().then(() => retireRuntime(ctx, sessions, session)).then(() =>
					null
				) as ReturnType<
					Behavior
				>;
			}
			throw new Error("unknown operator reset scope");
		}
		if (verb === GIVE_STEWARD) {
			if (args.length !== 1) throw new Error("giveSteward takes one durable room name");
			const bridge = bridges?.stewardship(typeof args[0] === "string" ? args[0] : "", session) ?? null;
			if (bridge !== null) {
				return bridges!.issueSteward(bridge.name, session).then((row) =>
					[
						row.name,
						row.label,
						row.visibility,
						BigInt(row.generation),
						row.issued,
						row.steward,
					] as Argument
				) as ReturnType<Behavior>;
			}
			const name = namedRoom(ctx, links, args[0]);
			return links.steward(name, session).then(() =>
				wireStewardshipRow(rowFor(ctx, links, session, name))
			) as ReturnType<
				Behavior
			>;
		}
		if (verb === GIVE_MANAGER) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("giveManager takes one room management identity");
			}
			return links.managerForIdentity(args[0], session).then((grant) => grant.manager) as ReturnType<Behavior>;
		}
		if (verb === REVOKE_STEWARD) {
			if (args.length !== 1) throw new Error("revokeSteward takes one durable room name");
			const bridge = bridges?.stewardship(typeof args[0] === "string" ? args[0] : "", session) ?? null;
			if (bridge !== null) {
				if (!bridge.issued || bridge.steward === null) {
					throw new RoomError(NOT_STEWARD, `IRC bridge "${bridge.label}" has no issued stewardship`);
				}
				return bridges!.revokeSteward(bridge.name).then(() => {
					const current = bridges!.stewardship(bridge.name, session);
					if (current == null) throw new Error("the IRC bridge stewardship disappeared while revoking");
					return wireStewardshipRow(current);
				}) as ReturnType<Behavior>;
			}
			const name = namedRoom(ctx, links, args[0]);
			if (!links.hasSteward(name)) {
				throw new RoomError(NOT_STEWARD, `Room "${name}" has no issued moderator capability.`);
			}
			return links.revokeSteward(name).then(() =>
				wireStewardshipRow(rowFor(ctx, links, session, name))
			) as ReturnType<
				Behavior
			>;
		}
		throw new Error(`Rooms operator has no method ${verb}`);
	};
}
