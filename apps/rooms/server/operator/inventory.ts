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
import { isPrivateRoomKey } from "../../lib/limits.ts";
import type { OperatorCategory } from "../../lib/protocol.ts";
import { introductions } from "../registry.ts";
import { revokeIntroduction } from "../introductions.ts";
import { troubleRows } from "../journal.ts";
import { disconnectOperatorSession, operatorIdForSession, operatorSessionFaces } from "../sessions.ts";
import type { RoomLinks } from "../room_links.ts";
import { operatorRoomFaces, removeOperatorRoom } from "./rooms.ts";
import { operatorReferenceFaces, releaseOperatorReference } from "./references.ts";
import { type OperatorRowSource, searchText } from "./page.ts";
import { liveRoom, type StewardshipRow, stewardshipRows, wireStewardshipRow } from "./stewardships.ts";

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
	links: RoomLinks,
	session: Session,
	category: OperatorCategory,
): Iterable<OperatorRowSource<OperatorRowFace>> {
	if (category === "stewardships") return stewardshipFaces(links, session);
	if (category === "links") return linkFaces(links);
	if (category === "registrations") return registrationFaces();
	if (category === "sessions") return sessionFaces(session);
	if (category === "rooms") return roomFaces();
	if (category === "references") return referenceFaces();
	return troubleFaces();
}

function* stewardshipFaces(links: RoomLinks, session: Session): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const row of stewardshipRows(links, session)) {
		yield face(
			searchText(row.name, row.label, row.visibility, row.issued ? "issued" : ""),
			() => wireStewardshipRow(row),
			row.issued ? () => links.revokeSteward(row.name).then(() => undefined) : null,
		);
	}
}

function* linkFaces(links: RoomLinks): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const { name } of links.named()) {
		const live = liveRoom(name);
		const privateRoom = live?.private ?? isPrivateRoomKey(name);
		const label = live?.name ?? (privateRoom ? "" : name);
		const visibility = privateRoom ? "private" : "listed";
		yield face(
			searchText(name, label, visibility),
			() => [name, label, visibility] as Argument,
			() => links.revokeRoomLink(name).then(() => undefined),
		);
	}
}

function* registrationFaces(): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const intro of introductions.values()) {
		const id = operatorIdForSession(intro.registrar);
		if (id == null) continue;
		yield face(
			searchText(intro.nick, id),
			() => [intro.nick, id] as Argument,
			() => {
				revokeIntroduction(intro.nick, intro.registrar);
			},
		);
	}
}

function* sessionFaces(caller: Session): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const source of operatorSessionFaces(caller)) {
		yield {
			text: source.text,
			build: () => {
				const row = source.build();
				return {
					wire: () => [row.id, row.transport, row.nick] as Argument,
					retire: () => {
						disconnectOperatorSession(row.id, caller);
					},
				};
			},
		};
	}
}

function* roomFaces(): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const source of operatorRoomFaces()) {
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
								const id = operatorIdForSession(member.session);
								return id == null ? [] : [[member.nick, id, member.state]];
							}),
							row.membersMore,
						] as Argument,
					retire: () => removeOperatorRoom(row.id).then(() => undefined),
				};
			},
		};
	}
}

function* referenceFaces(): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const source of operatorReferenceFaces()) {
		yield {
			text: source.text,
			build: () => {
				const row = source.build();
				return {
					wire: () => [row.id, row.kind, row.owner, row.room, row.member, row.detail] as Argument,
					retire: () => releaseOperatorReference(row.id),
				};
			},
		};
	}
}

function* troubleFaces(): Iterable<OperatorRowSource<OperatorRowFace>> {
	for (const row of troubleRows()) {
		yield face(
			searchText(row.source, row.reason),
			() => [row.source, row.reason, BigInt(row.count)] as Argument,
			null,
		);
	}
}

export type { StewardshipRow };
