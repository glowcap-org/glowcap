// Reconcile one attached session archive read with the live log already drawn.
// Archive coordinates name the same message across both paths. A missing row
// is inserted by time. An existing row receives the archive's current edit,
// withdrawal, and file shape without replacing unchanged file custody.

import * as store from "../store.ts";
import type { ArchiveLine, ArchiveRecord } from "../../../lib/archive/protocol.ts";
import { adoptableArchiveDigests, archivedAttachmentsMatch, archivedAttachmentViews } from "../archive_attachments.ts";
import { fetchesOnArrival } from "../media.ts";
import { type Item, silencedFrom } from "../types.ts";
import type { RoomsPageContext } from "../page.ts";
import type { AttachedSessionFiles, FileDescription, HeldFile } from "./attached_files.ts";

const samePreviews = (current: readonly string[] | undefined, next: readonly string[]) =>
	(current?.length ?? 0) === next.length && next.every((url, index) => current?.[index] === url);

/** Apply the archive's current rows and report whether any remain visible. */
export function reconcileAttachedHistory(
	page: RoomsPageContext,
	key: string,
	records: readonly ArchiveRecord[],
	files: Pick<AttachedSessionFiles<FileDescription>, "holdArchived" | "adoptArchived" | "release" | "open"> | null,
	custody?: { readonly local: boolean; readonly peer: boolean },
	source?: (record: ArchiveLine, index: number) => HeldFile | null,
): boolean {
	const existing = new Map(
		store.historyOf(page.projection, key)
			.filter((item): item is Extract<Item, { kind: "chat" }> => item.kind === "chat" && item.history != null)
			.map((item) => [store.historyCoordinateKey(item.history!), item]),
	);
	const materialize = (record: ArchiveLine) => ({
		from: record.from,
		text: record.text,
		mine: record.mine,
		at: record.at,
		history: { source: record.source, generation: record.generation, id: record.id },
		order: record.order,
		edited: record.state === "edited",
		previewUrls: record.previewUrls,
		attachments: files == null
			? archivedAttachmentViews(record.attachments).map((attachment) =>
				store.attachmentView(page.projection, attachment)
			)
			: record.attachments.map((_attachment, index) => files.holdArchived(record, index, source)),
	});
	const openLine = (line: ReturnType<typeof materialize>) => {
		if (files == null) return;
		for (const attachment of line.attachments) {
			if (
				attachment.lost !== true &&
				fetchesOnArrival(attachment, silencedFrom(line.from, line.mine, page.projection.get().ignored))
			) files.open(key, attachment.id);
		}
	};
	const lines: ReturnType<typeof materialize>[] = [];
	const revisions = new Map<number, Partial<Item>>();
	let retained = false;
	for (const record of records) {
		if (record.kind !== "line") continue;
		const current = existing.get(store.historyCoordinateKey(record));
		if (record.state === "withdrawn") {
			if (current != null && current.withdrawn !== true) {
				files?.release(current.attachments ?? []);
				revisions.set(current.id, {
					at: record.at,
					text: "",
					withdrawn: true,
					previewUrls: undefined,
					attachments: undefined,
				});
			} else if (current != null && current.at !== record.at) {
				revisions.set(current.id, { at: record.at });
			}
			continue;
		}
		retained = true;
		if (current == null) {
			lines.push(materialize(record));
			continue;
		}
		const exactAttachments = archivedAttachmentsMatch(current, record);
		const adoptedDigests = exactAttachments ? null : adoptableArchiveDigests(current, record);
		if (adoptedDigests != null) {
			for (const [index, attachment] of (current.attachments ?? []).entries()) {
				if (adoptedDigests.has(attachment.id)) files?.adoptArchived(key, attachment.id, record, index, source);
			}
			store.updateAttachments(page.projection, key, adoptedDigests);
		}
		const attachmentsChanged = !exactAttachments && adoptedDigests == null;
		if (
			!attachmentsChanged && current.from === record.from && current.mine === record.mine &&
			current.at === record.at && current.order === record.order && current.text === record.text &&
			samePreviews(current.previewUrls, record.previewUrls) &&
			(current.edited === true) === (record.state === "edited") && current.withdrawn !== true
		) continue;
		const line = attachmentsChanged ? materialize(record) : null;
		if (attachmentsChanged) files?.release(current.attachments ?? []);
		revisions.set(current.id, {
			from: record.from,
			mine: record.mine,
			at: record.at,
			order: record.order,
			text: record.text,
			edited: record.state === "edited",
			withdrawn: false,
			previewUrls: record.previewUrls.length === 0 ? undefined : record.previewUrls,
			...(line == null ? {} : { attachments: line.attachments.length === 0 ? undefined : line.attachments }),
		});
		if (line !== null) openLine(line);
	}
	store.reviseItems(page.projection, key, revisions);
	const device = page.controllerSelection.getSnapshot().kind !== "attached";
	const local = custody?.local ?? true;
	const peer = custody?.peer ?? false;
	const keeper = peer && local
		? device ? keeperPeerAndDevice : keeperPeerAndSession
		: peer
		? keeperPeer
		: device
		? keeperDevice
		: keeperSession;
	store.reconcileHistory(page.projection, key, lines, keeper);
	for (const line of lines) openLine(line);
	return retained;
}

export type HistoryRead =
	| { phase: "loading" }
	| { phase: "ready"; records: ArchiveRecord[]; local: boolean; peer: boolean }
	| { phase: "unavailable"; error: string };
import {
	keeperDevice,
	keeperPeer,
	keeperPeerAndDevice,
	keeperPeerAndSession,
	keeperSession,
} from "../../../lib/text/attached.ts";

/** Render Rust-owned history read progress. Scheduling and freshness stay there. */
export function projectAttachedHistoryRead(
	page: RoomsPageContext,
	key: string,
	result: HistoryRead,
	files: Pick<AttachedSessionFiles<FileDescription>, "holdArchived" | "adoptArchived" | "release" | "open"> | null,
	source?: (record: ArchiveLine, index: number) => HeldFile | null,
): void {
	const room = store.getConv(page.projection, key);
	if (result.phase === "loading") {
		if (room?.type === "room" && room.earlierHistory === "unasked") {
			store.setEarlierHistory(page.projection, key, "loading");
		}
	} else if (result.phase === "ready") {
		const retained = reconcileAttachedHistory(page, key, result.records, files, {
			local: result.local,
			peer: result.peer,
		}, source);
		if (room?.type === "room") {
			store.setEarlierHistory(page.projection, key, retained ? "shown" : "empty");
		}
	} else {
		if (room?.type === "room") store.setEarlierHistory(page.projection, key, "unavailable");
		store.noteTrouble(page.projection, "shared session archive", result.error);
	}
}
