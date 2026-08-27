// The Rooms process's retained capability occurrences, and their owner-aware
// release paths. This is deliberately not a generic Host reference table.

import type { Ref } from "@pancake/runtime";
import { MAX_OPERATOR_PAGE } from "../../lib/limits.ts";
import {
	forgetForeignRoom,
	handBack,
	type Introduction,
	introductions,
	introductionsById,
	type Member,
	type PendingUpload,
	publicRooms,
	rooms,
	type RoomState,
	signalExchanges,
} from "../registry.ts";
import { dropUpload } from "../files.ts";
import { leaveRoom } from "../presence.ts";
import { dropSignalExchange, revokeIntroduction } from "../introductions.ts";
import { operatorPendingPeering, removeOperatorPendingPeering } from "../peering.ts";
import { notifyPublicRoom } from "../discovery.ts";
import { noteOperatorChange } from "./revision.ts";
import { type OperatorRowPage, type OperatorRowSource, queryPage, searchText } from "./page.ts";

export type OperatorReferenceKind =
	| "membership"
	| "line"
	| "upload"
	| "foreign-room"
	| "pending-peering"
	| "registration"
	| "offered-inbox"
	| "signaling"
	| "signal-exchange";

export interface OperatorReferenceRow {
	id: string;
	kind: OperatorReferenceKind;
	owner: string;
	room: string;
	member: string;
	detail: string;
}

interface RetainedReference {
	row: OperatorReferenceRow;
	release(): boolean;
}

const refIds = new WeakMap<Ref, string>();
let nextId = 1n;

function idFor(ref: Ref): string {
	let id = refIds.get(ref);
	if (id == null) {
		id = `ref-${nextId}`;
		nextId += 1n;
		refIds.set(ref, id);
	}
	return id;
}

function pendingId(id: string): string {
	return `ref-pending-${id}`;
}

function add(
	references: Map<string, RetainedReference>,
	ref: Ref,
	row: Omit<OperatorReferenceRow, "id">,
	release: () => boolean,
): void {
	const id = idFor(ref);
	references.set(id, { row: { ...row, id }, release });
}

function releaseMember(state: RoomState, member: Member): boolean {
	return leaveRoom(state, member.session);
}

function releaseLine(member: Member, ref: Ref): boolean {
	const at = member.lines.indexOf(ref);
	if (at < 0) return false;
	member.lines.splice(at, 1);
	handBack(member.session, ref, "operator-released room line authority");
	noteOperatorChange();
	return true;
}

function releaseUpload(state: RoomState, session: Parameters<typeof dropUpload>[1], upload: PendingUpload): boolean {
	if (!state.uploads.get(session)?.has(upload) || upload.spent) return false;
	dropUpload(state, session, upload);
	noteOperatorChange();
	return true;
}

function addRoomReferences(state: RoomState, references: Map<string, RetainedReference>): void {
	for (const member of state.members) {
		add(
			references,
			member.inbox,
			{
				kind: "membership",
				owner: "room membership",
				room: state.name,
				member: member.nick,
				detail: `${member.lines.length} recent line hold${member.lines.length === 1 ? "" : "s"}`,
			},
			() => releaseMember(state, member),
		);
		for (const ref of member.lines) {
			add(
				references,
				ref,
				{
					kind: "line",
					owner: "room line history",
					room: state.name,
					member: member.nick,
					detail: "recent editable line authority",
				},
				() => releaseLine(member, ref),
			);
		}
		for (const upload of state.uploads.get(member.session) ?? []) {
			if (upload.ref === null || upload.spent) continue;
			add(
				references,
				upload.ref,
				{
					kind: "upload",
					owner: "pending upload",
					room: state.name,
					member: member.nick,
					detail: `${upload.file.name} (${upload.size} bytes)`,
				},
				() => releaseUpload(state, member.session, upload),
			);
		}
	}
}

function addIntroductionReferences(intro: Introduction, references: Map<string, RetainedReference>): void {
	add(
		references,
		intro.inbox,
		{
			kind: "registration",
			owner: "directory registration",
			room: "",
			member: intro.nick,
			detail: "registration inbox and name claim",
		},
		() => revokeIntroduction(intro.nick, intro.registrar),
	);
	for (const [registrationId, ref] of intro.inboxes) {
		const peer = introductionsById.get(registrationId)?.nick ?? "departed registration";
		add(
			references,
			ref,
			{
				kind: "offered-inbox",
				owner: "directory registration",
				room: "",
				member: intro.nick,
				detail: `inbox offered to ${peer} (${registrationId})`,
			},
			() => {
				if (intro.inboxes.get(registrationId) !== ref) return false;
				intro.inboxes.delete(registrationId);
				handBack(intro.registrar, ref, "operator-released offered inbox");
				noteOperatorChange();
				return true;
			},
		);
	}
	if (intro.signaling !== null) {
		const ref = intro.signaling;
		add(
			references,
			ref,
			{
				kind: "signaling",
				owner: "directory registration",
				room: "",
				member: intro.nick,
				detail: "WebRTC signaling inbox",
			},
			() => {
				if (intro.signaling !== ref) return false;
				intro.signaling = null;
				handBack(intro.registrar, ref, "operator-released signaling inbox");
				noteOperatorChange();
				return true;
			},
		);
	}
}

/** Rebuild the current reference owners. Stable IDs live in the weak identity
 * table; this view never keeps a disappeared capability alive. */
function currentReferences(): Map<string, RetainedReference> {
	const references = new Map<string, RetainedReference>();
	for (const state of rooms.values()) addRoomReferences(state, references);
	for (const entry of publicRooms.values()) {
		if (entry.kind !== "foreign") continue;
		add(
			references,
			entry.room,
			{
				kind: "foreign-room",
				owner: "foreign room publication",
				room: entry.name,
				member: "",
				detail: `${entry.proof} publication from ${entry.origin}`,
			},
			() => {
				const removed = forgetForeignRoom(entry.id);
				if (removed === null) return false;
				notifyPublicRoom(removed, "closed", null);
				return true;
			},
		);
	}
	for (const pending of operatorPendingPeering()) {
		const id = pendingId(pending.id);
		references.set(id, {
			row: {
				id,
				kind: "pending-peering",
				owner: "pending foreign publication",
				room: pending.name,
				member: "",
				detail: `${pending.proof} publication from ${pending.origin}`,
			},
			release: () => removeOperatorPendingPeering(pending.id),
		});
	}
	for (const intro of introductions.values()) addIntroductionReferences(intro, references);
	for (const [id, exchange] of signalExchanges) {
		add(
			references,
			exchange.reply,
			{
				kind: "signal-exchange",
				owner: "signaling exchange",
				room: "",
				member: "",
				detail: `in-flight exchange ${id}`,
			},
			() => {
				if (!signalExchanges.has(id)) return false;
				dropSignalExchange(id, "operator released signaling exchange");
				return true;
			},
		);
	}
	return references;
}

/** Build the bounded view of references the process still owns. IDs remain
 * stable while the same Ref or pending publication occurrence remains live. */
/** Every retained reference, as rows a search can scan. The detail sentence
 * is part of the text, because it is where a reference says which room, file,
 * or exchange it is holding open. */
export function* operatorReferenceFaces(): Iterable<OperatorRowSource<OperatorReferenceRow>> {
	const references = currentReferences();
	const rows = [...references.values()].map((reference) => reference.row).sort((left, right) =>
		left.id.localeCompare(right.id)
	);
	for (const row of rows) {
		yield {
			text: searchText(row.id, row.kind, row.owner, row.room, row.member, row.detail),
			build: () => row,
		};
	}
}

export function operatorReferencePage(
	offset: number,
	limit: number,
	query = "",
): OperatorRowPage<OperatorReferenceRow> {
	if (
		!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 ||
		limit > MAX_OPERATOR_PAGE
	) {
		throw new Error("operator reference page cursor or limit is out of range");
	}
	return queryPage(operatorReferenceFaces(), query, offset, limit);
}

export function releaseOperatorReference(id: string): void {
	const reference = currentReferences().get(id);
	if (reference == null || !reference.release()) {
		throw new Error("that retained reference is no longer present");
	}
}
