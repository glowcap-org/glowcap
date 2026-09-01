// The glue between delivered lines and the device's history.
//
// `ui/history.ts` owns the bytes and the archive backend; the store owns the
// log and does no I/O. This file is the seam: it mints the recorder's opaque
// conversation generation and record ids, files each delivered line, and
// hydrates older generations under explicit archive dividers. A room's own
// retained tail remains the room's account; this is the member's bounded
// account of what reached their screen.

import * as store from "../store.ts";
import {
	type Conv,
	type DmConv,
	isSessionConv,
	type Item,
	type RoomConv,
	type SessionConv,
	silencedFrom,
} from "../types.ts";
import { ARCHIVED_BYTES_UNAVAILABLE, archivedAttachmentViews } from "../archive_attachments.ts";
import { pickedSource } from "../file_source.ts";
import { fetchesOnArrival } from "../media.ts";
import { openAttachment } from "./files.ts";
import type { AttachmentProgress, HeldFile } from "./live.ts";
import { convSession } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import {
	forgetHistoryLine,
	type HistoryCoordinates,
	historyKept,
	readLines,
	recordHistoryLine,
	recordHistoryStanding,
	setHistoryTroubleReporter,
	type StoredLine,
	updateHistoryLine,
} from "../history.ts";
import { archiveConversationIdentity } from "../../../lib/archive/handover.ts";
import type { ArchiveRecord } from "../../../lib/archive/protocol.ts";
import type { AttachmentSource } from "../../../lib/attachment.ts";
/** Conversation-generation and record-id maps for this page's archive glue. */
export class PageHistoryCoords {
	readonly generations = new Map<string, string>();
	readonly recordIds = new Map<string, string>();
	readonly hydrations = new Map<string, symbol>();
	/** The rows behind archived files, by conversation and by file.
	 *
	 * Here rather than on the directory's session, because these bytes are in
	 * this browser's own storage and whether a directory happens to be reachable
	 * has nothing to do with reading them. Homing them on the session is what let
	 * a cold start — where the archive is read before the first connection lands
	 * — record "no session yet" as "these bytes are gone", permanently, for a
	 * file sitting on the disk. A reconnect did the same thing on the way past.
	 *
	 * They are released when the lines carrying them are dropped and when the
	 * conversation closes, which is what lets a swapped-out archive target
	 * finish retiring. */
	readonly archived = new Map<string, Map<number, HeldFile>>();
	/** Object URLs minted from archived bytes, by the file that shows one. The
	 * session keeps its own; these outlive it. */
	readonly urls = new Map<number, string>();
	/** Read cadence for archived bytes, coalesced exactly as a session's is. */
	readonly progress: AttachmentProgress = { pending: new Map(), frame: null };
}

/** The archived rows for one conversation, made on first use. */
function archivedRows(page: RoomsPageContext, key: string): Map<number, HeldFile> {
	let rows = page.history.archived.get(key);
	if (rows === undefined) {
		rows = new Map();
		page.history.archived.set(key, rows);
	}
	return rows;
}

/** Let go of the archived rows for one conversation's files, whether or not any
 * directory is reachable. Releasing a row is what hands its generation back to
 * the archive, so a target being swapped out can finish retiring. */
export function releaseArchivedFiles(page: RoomsPageContext, key: string, ids?: Iterable<number>): void {
	const rows = page.history.archived.get(key);
	if (rows === undefined) return;
	for (const id of ids ?? [...rows.keys()]) {
		rows.get(id)?.release();
		rows.delete(id);
		const url = page.history.urls.get(id);
		if (url !== undefined) {
			URL.revokeObjectURL(url);
			page.history.urls.delete(id);
		}
	}
	if (rows.size === 0) page.history.archived.delete(key);
}

function contextOf(
	conv: RoomConv | DmConv,
): Pick<HistoryCoordinates, "conversationKind" | "directory" | "conversation"> {
	// The authority identity is stable when routing hints change; a dialable
	// address is not. Generation records key on the former.
	return {
		conversationKind: conv.type === "room" ? "room" : "direct",
		directory: conv.dir,
		conversation: archiveConversationIdentity(conv),
	};
}

/** A line that left the bounded UI log can no longer receive an edit there, so
 * its tab-local mapping can leave too. The archive record itself stays. */
export function dropArchiveLineCoordinates(page: RoomsPageContext, key: string, gone: readonly Item[]): void {
	for (const item of gone) page.history.recordIds.delete(`${key}\u0000${item.id}`);
}

/** Closing a direct conversation ends its live generation. A later
 * introduction mints another even when the directory grants the same name. */
export function closeArchiveGeneration(page: RoomsPageContext, key: string): void {
	page.history.generations.delete(key);
	page.history.hydrations.delete(key);
	releaseArchivedFiles(page, key);
}

function generationOf(page: RoomsPageContext, conv: Conv): string {
	let generation = page.history.generations.get(conv.key);
	if (generation === undefined) {
		generation = crypto.randomUUID();
		page.history.generations.set(conv.key, generation);
	}
	return generation;
}

function coordinatesOf(page: RoomsPageContext, conv: RoomConv | DmConv, item: Item): HistoryCoordinates {
	const key = `${conv.key}\u0000${item.id}`;
	let id = page.history.recordIds.get(key);
	if (id === undefined) {
		id = crypto.randomUUID();
		page.history.recordIds.set(key, id);
	}
	return { ...contextOf(conv), generation: generationOf(page, conv), id };
}

function archiveSources(page: RoomsPageContext, conv: Conv, item: Extract<Item, { kind: "chat" }>): AttachmentSource[] {
	const views = item.attachments ?? [];
	if (views.length === 0) return [];
	const owner = convSession(page, conv.key);
	const outgoing = owner?.outgoing.get(item.id);
	const sources: AttachmentSource[] = [];
	for (const view of views) {
		const outgoingIndex = outgoing?.attachmentIds.indexOf(view.id) ?? -1;
		if (outgoing != null && outgoingIndex >= 0) {
			sources.push(pickedSource(outgoing.files[outgoingIndex]));
			continue;
		}
		const held = owner?.files.get(view.id);
		if (held == null) return [];
		let bytes: Promise<Uint8Array> | null = null;
		sources.push({
			name: view.name,
			mime: view.mime,
			size: view.size,
			width: view.width,
			height: view.height,
			read: async (offset, length) => {
				bytes ??= held.fetch();
				const loaded = await bytes;
				return loaded.subarray(offset, offset + length);
			},
		});
	}
	return sources;
}

function record(page: RoomsPageContext, conv: Conv, item: Item, change?: "withdrawn" | "edited"): void {
	if (item.kind !== "chat" || !isSessionConv(conv)) return;
	const coordinates = coordinatesOf(page, conv, item);
	const sources = archiveSources(page, conv, item);
	const line = {
		from: item.from,
		text: item.text,
		mine: item.mine,
		at: item.at,
		attachments: (item.attachments ?? []).map(({ name, mime, size, width = 0, height = 0 }) => ({
			name,
			mime,
			size,
			width,
			height,
			blob: null,
		})),
	};
	if (change === "withdrawn") {
		forgetHistoryLine(page, coordinates, line);
		return;
	}
	if (change === "edited") {
		updateHistoryLine(page, coordinates, line, sources);
		return;
	}
	recordHistoryLine(page, coordinates, line, sources);
}

/** Install the recorder on the store's one deliver seam. Called once at
 * boot; the store stays sync and I/O-free, this side owns the writing. */
export function installHistoryRecorder(page: RoomsPageContext): void {
	setHistoryTroubleReporter(page, (source, reason) => store.noteTrouble(page.projection, source, reason));
	page.projection.setLineRecorder((conv, item, change) => record(page, conv, item, change));
}

function shortId(value: string): string {
	return value.slice(0, 8);
}

/** Add one peer's scoped archive account under its own attribution. Direction
 * is never imported: `mine` was true for the other recorder, not this reader. */
export function prependSharedArchive(
	page: RoomsPageContext,
	key: string,
	records: readonly ArchiveRecord[],
	from: string,
): void {
	const groups = new Map<string, {
		source: string;
		generation: string;
		lines: StoredLine[];
		standings: string[];
	}>();
	for (const record of records) {
		if (record.kind === "standing") {
			const groupKey = `${record.source}\u0000${record.generation}`;
			let group = groups.get(groupKey);
			if (group === undefined) {
				group = { source: record.source, generation: record.generation, lines: [], standings: [] };
				groups.set(groupKey, group);
			}
			group.standings.push(`${record.nick} in ${record.room}`);
			continue;
		}
		if (record.kind !== "line" || record.state === "withdrawn") continue;
		const groupKey = `${record.source}\u0000${record.generation}`;
		let group = groups.get(groupKey);
		if (group === undefined) {
			group = { source: record.source, generation: record.generation, lines: [], standings: [] };
			groups.set(groupKey, group);
		}
		group.lines.push({
			from: record.from,
			text: record.text,
			mine: false,
			at: record.at,
			attachments: record.attachments,
		});
	}
	const ordered = [...groups.values()];
	for (const group of ordered) group.lines.sort((a, b) => a.at - b.at);
	ordered.sort((a, b) => (a.lines[0]?.at ?? 0) - (b.lines[0]?.at ?? 0));
	for (const group of ordered.reverse()) {
		const standing = group.standings.length === 0 ? "" : ` Standing recorded: ${group.standings.join("; ")}.`;
		if (group.lines.length === 0) {
			if (standing !== "") {
				store.deliver(
					page.projection,
					key,
					store.sysItem(
						page.projection,
						`Standing shared by ${from}, recorded by archive source ${shortId(group.source)}. ` +
							`This is ${from}'s archive account, not live membership.` + standing,
					),
				);
			}
			continue;
		}
		store.prependHistory(
			page.projection,
			key,
			group.lines.map((line) => ({
				...line,
				attachments: archivedAttachmentViews(line.attachments),
			})),
			`Earlier messages shared by ${from}, recorded by archive source ${shortId(group.source)}, ` +
				`conversation ${shortId(group.generation)}. This is ${from}'s archive account, not live traffic.` +
				standing,
		);
	}
}

/** Stand what the device remembers under a direct conversation, one explicitly
 * attributed archive generation at a time. Iterating newest first is what
 * leaves the final prepended log oldest-first. */
export function hydrateDm(page: RoomsPageContext, conv: DmConv): void {
	hydrateConversation(page, conv);
}

export function hydrateRoom(page: RoomsPageContext, conv: RoomConv): void {
	hydrateConversation(page, conv);
}

export function hydrateConversation(page: RoomsPageContext, conv: SessionConv): void {
	if (conv.type === "room" && historyKept(page)) {
		recordHistoryStanding(page, {
			generation: generationOf(page, conv),
			directory: conv.dir,
			conversation: archiveConversationIdentity(conv),
		}, store.dirNick(page.projection, conv.dir));
	}
	if (!historyKept(page) || page.history.hydrations.has(conv.key)) return;
	const token = Symbol(conv.persistId);
	page.history.hydrations.set(conv.key, token);
	const context = contextOf(conv);
	void readLines(page, context.conversationKind ?? "direct", context.directory, context.conversation).then(
		(groups) => {
			if (page.history.hydrations.get(conv.key) !== token) {
				for (const group of groups) group.release();
				return;
			}
			const current = store.getConv(page.projection, conv.key);
			if (current == null || !isSessionConv(current) || current.persistId !== conv.persistId) {
				for (const group of groups) group.release();
				return;
			}
			for (const group of [...groups].reverse()) {
				// Whether the archive holds the bytes, and nothing else. Whether a
				// directory is reachable is a fact about the network; this one is
				// about the disk, and asking both here is what made every cold start
				// a coin flip over its own files.
				let heldAttachments = 0;
				const rows = archivedRows(page, conv.key);
				const lines = group.lines.map((line) => {
					const archive = line.archive;
					const attachments = archive?.attachments.map((metadata, index) => {
						const { blob: _blob, ...fields } = metadata;
						const available = metadata.blob != null;
						const view = store.attachmentView(page.projection, {
							...fields,
							...(available ? {} : { lost: true, error: ARCHIVED_BYTES_UNAVAILABLE }),
						});
						if (available) {
							heldAttachments += 1;
							let held = true;
							rows.set(view.id, {
								attachment: fields,
								fetch: (onProgress) => group.readAttachment(archive, index, onProgress),
								release: () => {
									if (!held) return;
									held = false;
									heldAttachments -= 1;
									if (heldAttachments === 0) group.release();
								},
							});
						}
						return view;
					}) ?? [];
					return { ...line, attachments };
				});
				const attribution = `by archive source ${shortId(group.source)}, conversation ${
					shortId(group.generation)
				}`;
				const keeper = group.keeper === "this device" ? "kept on this device" : `kept by ${group.keeper}`;
				store.prependHistory(
					page.projection,
					conv.key,
					lines,
					conv.type === "dm"
						? `Earlier messages, ${keeper} ${attribution}. This directory name's holder may have changed`
						: `Earlier messages observed by this member, ${keeper} ${attribution}`,
				);
				if (heldAttachments === 0) group.release();
				for (const line of lines) {
					for (const attachment of line.attachments) {
						if (
							attachment.lost !== true &&
							fetchesOnArrival(
								attachment,
								silencedFrom(line.from, line.mine, page.projection.get().ignored),
							)
						) openAttachment(page, conv.key, attachment.id);
					}
				}
			}
		},
	).catch((error) => {
		if (page.history.hydrations.get(conv.key) === token) page.history.hydrations.delete(conv.key);
		store.noteTrouble(page.projection, "message history", error instanceof Error ? error.message : String(error));
	});
}
