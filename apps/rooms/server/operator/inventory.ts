// Every operator inventory behind one shape, so a search and a bulk act are
// written once rather than seven times.
//
// A category answers with rows a search can scan (`page.ts`), and each row
// carries both what the wire sends and, where the row can be retired one at a
// time, the act that retires it. That second half is what makes an act on a
// search possible: "release every reference matching this" is the per-row act
// this file already names, applied to the rows the same scan already found.
//
// Trouble rows have no per-row act because the journal is acknowledged whole,
// and a stewardship row has one only while it has an issued capability to
// revoke.

import type { Argument, Session } from "@pancake/runtime";
import { roomIsListed } from "../../lib/room/policy.ts";
import type { OperatorCategory, OperatorReferenceKind } from "../../lib/operator_vocabulary.ts";
import type { RoomServerContext } from "../context.ts";
import { revokeIntroduction } from "../introductions.ts";
import type { RoomServerSessions } from "../sessions.ts";
import type { RoomLinks } from "../room_links.ts";
import { operatorRoomFaces, removeOperatorRoom } from "./rooms.ts";
import type { OperatorReferenceInventory } from "./references.ts";
import { matchesQuery, type OperatorRowSource, searchText } from "./page.ts";
import { liveRoom, type StewardshipRow, stewardshipRows, wireStewardshipRow } from "./stewardships.ts";
import type { IrcBridgeAuthorities } from "../irc_gateway/authority.ts";
import { isManagedRoomId } from "../../lib/limits.ts";

/** One inventory row: what the wire sends, and how this server retires it.
 * `retire` is null when the row is not something to retire one at a time. */
export interface OperatorRowFace {
	wire(): Argument;
	retire: (() => Promise<void> | void) | null;
}

function face(
	text: string,
	wire: () => Argument,
	retire: (() => Promise<void> | void) | null,
): OperatorRowSource<OperatorRowFace> {
	return { text, build: () => ({ wire, retire }) };
}

export function operatorFaces(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	sessions: RoomServerSessions,
	references: OperatorReferenceInventory,
	category: OperatorCategory,
	referenceKind: OperatorReferenceKind | null = null,
	bridges: IrcBridgeAuthorities | null = null,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	if (category === "stewardships") return stewardshipFaces(ctx, links, session, bridges);
	if (category === "links") return linkFaces(ctx, links);
	if (category === "registrations") return registrationFaces(ctx, sessions, session);
	if (category === "sessions") return sessionFaces(sessions, session);
	if (category === "rooms") return roomFaces(ctx, sessions);
	if (category === "references") return referenceFaces(references, referenceKind);
	return troubleFaces(ctx);
}

function* stewardshipFaces(
	ctx: RoomServerContext,
	links: RoomLinks,
	session: Session,
	bridges: IrcBridgeAuthorities | null,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const row of stewardshipRows(ctx, links, session, bridges)) {
		const bridge = bridges?.stewardship(row.name, session) ?? null;
		yield face(
			searchText(row.name, row.label, row.visibility, row.issued ? "issued" : ""),
			() => wireStewardshipRow(row),
			row.issued
				? () =>
					(bridge == null ? links.revokeSteward(row.name) : bridges!.revokeSteward(row.name))
						.then(() => undefined)
				: null,
		);
	}
}

/** How this directory names one durable room link: the durable name its verbs
 * take, the label a person reads, and whether the room is listed. A private
 * room has no label, because its label was never its identity.
 *
 * Exported because the inspect capability lists the same links and has to name
 * them the same way. Two copies of this resolution would drift, and the way it
 * showed would be one page calling a room `design` while the other called the
 * same room by its durable key. */
export function linkFace(
	ctx: RoomServerContext,
	links: RoomLinks,
	name: string,
): { name: string; label: string; visibility: "listed" | "private" } {
	const live = liveRoom(ctx, name);
	const managed = links.managedRoom(name);
	const privateRoom = live != null
		? !roomIsListed(live.policy)
		: managed != null
		? !roomIsListed(managed.policy)
		: isManagedRoomId(name);
	return {
		name,
		label: live?.name ?? managed?.name ?? (privateRoom ? "" : name),
		visibility: privateRoom ? "private" : "listed",
	};
}

function* linkFaces(ctx: RoomServerContext, links: RoomLinks): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const { name } of links.named()) {
		const { label, visibility } = linkFace(ctx, links, name);
		yield face(
			searchText(name, label, visibility),
			() => [name, label, visibility] as Argument,
			() => links.revokeRoomLink(name).then(() => undefined),
		);
	}
}

function* registrationFaces(
	ctx: RoomServerContext,
	sessions: RoomServerSessions,
	caller: Session,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const intro of ctx.live.introductions.values()) {
		const id = sessions.operatorIdFor(intro.registrar);
		if (id == null) continue;
		yield face(
			searchText(intro.nick, id),
			() => [intro.nick, id, intro.registrar === caller] as Argument,
			() => {
				revokeIntroduction(ctx, intro.nick, intro.registrar);
			},
		);
	}
}

function* sessionFaces(
	sessions: RoomServerSessions,
	caller: Session,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const source of sessions.operatorFaces(caller)) {
		yield {
			text: source.text,
			build: () => {
				const row = source.build();
				return {
					wire: () => [row.id, row.transport, row.nick, row.you] as Argument,
					retire: () => {
						if (!sessions.disconnect(row.id, caller)) {
							throw new Error("this operator's own connection stays");
						}
					},
				};
			},
		};
	}
}

function* roomFaces(
	ctx: RoomServerContext,
	sessions: RoomServerSessions,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const source of operatorRoomFaces(ctx)) {
		yield {
			text: source.text,
			build: () => {
				const row = source.build();
				return {
					wire: () =>
						[
							row.id,
							row.kind,
							row.name,
							row.origin,
							row.proof,
							row.retainedCapabilities === null ? null : BigInt(row.retainedCapabilities),
							row.members.flatMap((member) => {
								const id = sessions.operatorIdFor(member.session);
								return id == null ? [] : [[member.nick, id, member.state]];
							}),
							row.membersMore,
						] as Argument,
					retire: () => removeOperatorRoom(ctx, row.id).then(() => undefined),
				};
			},
		};
	}
}

function* referenceFaces(
	references: OperatorReferenceInventory,
	kind: OperatorReferenceKind | null,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	let current: OperatorRowSource<import("./references.ts").OperatorReferenceRow> | null = null;
	const projected: OperatorRowSource<OperatorRowFace> = {
		get text() {
			return current?.text ?? "";
		},
		get kind() {
			return current?.kind;
		},
		get active() {
			return current?.active;
		},
		matches: (words) => current?.matches?.(words) ?? (current != null && matchesQuery(current.text, words)),
		build: () => {
			if (current == null) throw new Error("operator reference projection has no current row");
			const selected = current;
			const row = selected.build();
			return {
				wire: () => [row.id, row.kind, row.owner, row.room, row.member, row.detail] as Argument,
				retire: () => {
					if (selected.retire?.()) return;
					throw new Error("that retained reference is no longer present");
				},
			};
		},
	};
	for (const source of references.faces()) {
		if (kind !== null && source.kind !== kind) continue;
		if (source.active?.() === false) continue;
		current = source;
		yield projected;
	}
}

function* troubleFaces(ctx: RoomServerContext): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const row of ctx.journal.rows()) {
		yield face(
			searchText(row.source, row.reason),
			() => [row.source, row.reason, BigInt(row.count)] as Argument,
			null,
		);
	}
}

export type { StewardshipRow };
