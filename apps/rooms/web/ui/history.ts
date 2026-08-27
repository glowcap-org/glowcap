// Room and direct-message history, kept by the member's selected archive.
//
// A direct line is end-to-end encrypted, so its plaintext must never land on
// the room server. The tab records it through the member-owned archive seam
// (ADR-0129), backed by this browser profile's `rooms-history` IndexedDB until
// the reader selects a peer (ADR-0131). A refused write still lets the page
// carry on: retained history is never a condition of send, and a peer failure
// never falls back to a second store.
//
// The archive keeps text, bounded attachment metadata, and bytes when its
// backend supports blob custody. Byte access remains capability-backed and
// separate from checkpoint state. An edit replaces the stored text, and a
// withdrawal replaces it with an empty withdrawn record, so plaintext and file
// authority do not survive behind the takedown. Every visible generation
// carries the recorder coordinates the archive actually stored; older
// prerelease schemas are reset rather than shown under invented provenance.

import type { ArchivedAttachment, ArchiveLine, ArchiveRecord } from "../../lib/archive.ts";
import type { AttachmentSource } from "../../lib/attachment.ts";
import {
	type ArchivedAttachmentRead,
	type ArchivedAttachmentSource,
	isBlobArchiveBackend,
	lineAttachmentAddress,
} from "../../lib/archive_blobs.ts";
import { BLOB_CHUNK } from "../../lib/limits.ts";
import {
	historyRetentionEpoch,
	readTabArchiveContext,
	setHistoryRetentionEpoch,
	tabArchiveBackend,
} from "./archive_store.ts";

let reportHistoryTrouble: (source: string, reason: string) => void = () => {};

/** Bind write failures to the presentation owner. Attached views do not record,
 * so local boot installs this once before any line can arrive. */
export function setHistoryTroubleReporter(report: (source: string, reason: string) => void): void {
	reportHistoryTrouble = report;
}

let keepHistory = true;
let retentionEpoch = historyRetentionEpoch();

function archiveSource(
	metadata: ArchiveLine["attachments"][number],
	source: AttachmentSource,
): ArchivedAttachmentSource {
	return {
		...metadata,
		read: async (offset, length) => {
			const bytes = source.bytes?.subarray(offset, offset + length) ?? await source.read?.(offset, length);
			if (!(bytes instanceof Uint8Array) || bytes.length !== length) {
				throw new Error(
					`archive attachment source answered ${bytes?.length ?? 0} of ${length} requested bytes`,
				);
			}
			return bytes;
		},
	};
}

/** One remembered line, exactly what a bubble needs to stand again. */
export interface StoredLine {
	readonly from: string;
	readonly text: string;
	readonly mine: boolean;
	readonly at: number;
	readonly attachments: readonly ArchivedAttachment[];
	readonly archive?: ArchiveLine;
}

/** One explicitly attributed run returned to the interface. */
export interface StoredGeneration {
	readonly source: string;
	readonly generation: string;
	readonly keeper: string;
	readonly lines: StoredLine[];
	readAttachment(record: ArchiveLine, index: number, onProgress?: (got: number) => void): Promise<Uint8Array>;
	release(): void;
}

/** One selected archive implementation. The tab backend and a remote peer
 * differ only here; record semantics remain in `lib/archive.ts`. */
export interface HistoryArchiveTarget {
	readonly kind: "device" | "peer" | "unavailable";
	readonly keeper: string;
	put(record: ArchiveLine, attachments?: readonly AttachmentSource[]): Promise<unknown>;
	read(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]>;
	attachment(record: ArchiveLine, index: number, onProgress?: (got: number) => void): Promise<Uint8Array>;
	retire(): Promise<void>;
}

async function materializeArchivedAttachment(
	found: ArchivedAttachmentRead | null,
	onProgress?: (got: number) => void,
): Promise<Uint8Array> {
	if (found == null) throw new Error("those archived file bytes are unavailable");
	const bytes = new Uint8Array(found.attachment.size);
	for (let offset = 0; offset < bytes.length; offset += BLOB_CHUNK) {
		const length = Math.min(BLOB_CHUNK, bytes.length - offset);
		const chunk = await found.attachment.read(offset, length);
		if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
			throw new Error(`archived file answered ${chunk?.length ?? 0} of ${length} requested bytes`);
		}
		bytes.set(chunk, offset);
		onProgress?.(offset + chunk.length);
	}
	return bytes;
}

const deviceTarget: HistoryArchiveTarget = {
	kind: "device",
	keeper: "this device",
	put: (record, attachments = []) =>
		attachments.length > 0 && isBlobArchiveBackend(tabArchiveBackend)
			? tabArchiveBackend.putWithAttachments(
				record,
				attachments.map((attachment, index) => archiveSource(record.attachments[index], attachment)),
			)
			: tabArchiveBackend.put(record),
	read: readTabArchiveContext,
	attachment: async (record, index, onProgress) =>
		await materializeArchivedAttachment(
			await tabArchiveBackend.readAttachment(lineAttachmentAddress(record, index)),
			onProgress,
		),
	retire: () => Promise.resolve(),
};

interface TargetSlot {
	readonly target: HistoryArchiveTarget;
	uses: number;
	idle: (() => void)[];
}

let targetSlot: TargetSlot = { target: deviceTarget, uses: 0, idle: [] };

function holdTargetSlot(slot: TargetSlot): () => void {
	slot.uses += 1;
	let held = true;
	return () => {
		if (!held) return;
		held = false;
		slot.uses -= 1;
		if (slot.uses === 0) {
			for (const settle of slot.idle.splice(0)) settle();
		}
	};
}

async function withTarget<T>(slot: TargetSlot, use: (target: HistoryArchiveTarget) => Promise<T>): Promise<T> {
	const release = holdTargetSlot(slot);
	try {
		return await use(slot.target);
	} finally {
		release();
	}
}

function whenIdle(slot: TargetSlot): Promise<void> {
	if (slot.uses === 0) return Promise.resolve();
	return new Promise((resolve) => slot.idle.push(resolve));
}

/** Hold the recorder currently selected at this instant. A caller preparing
 * passable authority keeps this lease until the authority has crossed or been
 * abandoned, so an overlapping target swap cannot close its session between
 * mint and handoff. */
export function holdHistoryArchiveTarget(): { target: HistoryArchiveTarget; release(): void } {
	const slot = targetSlot;
	return { target: slot.target, release: holdTargetSlot(slot) };
}

/** Change where subsequent records go. Earlier queued writes finish against
 * their old target. Active reads and displayed archived-file occurrences may
 * keep that target draining after the new selection has returned. */
export async function activateHistoryArchiveTarget(next: HistoryArchiveTarget): Promise<void> {
	const prior = targetSlot;
	if (prior.target === next) return;
	const deferRetirement = prior.uses > 0;
	const admitted = writes;
	targetSlot = { target: next, uses: 0, idle: [] };
	await admitted;
	const retire = whenIdle(prior).then(() => prior.target.retire());
	if (!deferRetirement) await retire;
	else {
		void retire.catch((error) => {
			reportHistoryTrouble("archive target retirement", error instanceof Error ? error.message : String(error));
		});
	}
}

export function useDeviceHistoryArchive(): Promise<void> {
	return activateHistoryArchiveTarget(deviceTarget);
}

export function unavailableHistoryArchiveTarget(label: string): HistoryArchiveTarget {
	return {
		kind: "unavailable",
		keeper: label,
		put: () => Promise.reject(new Error("the selected archive peer is unavailable")),
		read: () => Promise.resolve([]),
		attachment: () => Promise.reject(new Error("the selected archive peer is unavailable")),
		retire: () => Promise.resolve(),
	};
}

export interface HistoryCoordinates {
	readonly conversationKind?: "room" | "direct";
	readonly generation: string;
	readonly id: string;
	readonly directory: string;
	readonly conversation: string;
}

/** Whether the selected archive admits new message records. */
export function historyKept(): boolean {
	return keepHistory;
}

/** Install the validated bundle preference before a directory can deliver. */
export function restoreHistoryPreference(keep: boolean): void {
	keepHistory = keep;
}

/** Change retention only after the browser has committed its storage boundary.
 * Turning device retention off advances that boundary and clears in one
 * transaction; queued writes admitted by any tab under the old epoch can no
 * longer put an erased line back. */
export async function setHistoryKept(keep: boolean): Promise<void> {
	const nextEpoch = crypto.randomUUID();
	const erase = !keep && targetSlot.target.kind === "device";
	await writes;
	await setHistoryRetentionEpoch(nextEpoch, erase);
	if (erase) tabArchiveBackend.clearVolatile();
	retentionEpoch = Promise.resolve(nextEpoch);
	keepHistory = keep;
}

let writes: Promise<void> = Promise.resolve();

/** Settle every record operation queued before this call. A share boundary
 * uses this before minting a facet so the offered account includes everything
 * the sender has already seen drawn. Later lines remain later writes. */
export function settleHistoryWrites(): Promise<void> {
	return writes;
}

function enqueueWrite(write: () => Promise<void>): void {
	// One line may be put, edited, and withdrawn in adjacent UI turns. Preserve
	// that order even when the first operation had to open IndexedDB or mint the
	// recorder source. A failure remains visible but never poisons the queue.
	writes = writes.then(write, write).catch((error) => {
		reportHistoryTrouble("message history write", error instanceof Error ? error.message : String(error));
	});
}

function archiveLine(
	coordinates: HistoryCoordinates,
	line: StoredLine,
	state: ArchiveLine["state"],
	source: string,
): ArchiveLine {
	return {
		kind: "line",
		source,
		generation: coordinates.generation,
		id: coordinates.id,
		conversationKind: coordinates.conversationKind ?? "direct",
		directory: coordinates.directory,
		conversation: coordinates.conversation,
		from: line.from,
		text: state === "withdrawn" ? "" : line.text,
		mine: line.mine,
		at: line.at,
		state,
		attachments: state === "withdrawn" ? [] : line.attachments,
	};
}

function putDmLine(
	coordinates: HistoryCoordinates,
	line: StoredLine,
	state: ArchiveLine["state"],
	attachments: readonly AttachmentSource[] = [],
): void {
	if (!historyKept()) return;
	const selected = targetSlot;
	const epoch = selected.target.kind === "device" ? retentionEpoch : null;
	enqueueWrite(async () => {
		const source = await tabArchiveBackend.source();
		const record = archiveLine(coordinates, line, state, source);
		await withTarget(
			selected,
			(target) =>
				target.kind === "device" && epoch != null
					? epoch.then((expected) =>
						attachments.length > 0
							? tabArchiveBackend.putRetainedWithAttachments(
								record,
								attachments.map((attachment, index) =>
									archiveSource(record.attachments[index], attachment)
								),
								expected,
							)
							: tabArchiveBackend.putRetained(record, expected)
					)
					: target.put(record, attachments),
		);
	});
}

/** Insert one line under this recorder's explicit source and conversation
 * generation. Fire-and-forget: the caller has already drawn the line. */
export function recordHistoryLine(
	coordinates: HistoryCoordinates,
	line: StoredLine,
	attachments: readonly AttachmentSource[] = [],
): void {
	putDmLine(coordinates, line, "present", attachments);
}

/** A line was edited: the same archive key receives the new words and a new
 * revision, so readers that already saw it see the replacement. */
export function updateHistoryLine(
	coordinates: HistoryCoordinates,
	line: StoredLine,
	attachments: readonly AttachmentSource[] = [],
): void {
	putDmLine(coordinates, line, "edited", attachments);
}

/** A line was withdrawn: replace the record with an empty withdrawn state.
 * The state remains observable; the plaintext does not. */
export function forgetHistoryLine(coordinates: HistoryCoordinates, line: StoredLine): void {
	putDmLine(coordinates, line, "withdrawn");
}

/** Everything remembered for this directory name, separated by the recorder
 * source and live conversation generation it actually belongs to. */
export async function readHistoryLines(
	directory: string,
	conversation: string,
): Promise<StoredGeneration[]> {
	return await readLines("direct", directory, conversation);
}

/** Everything remembered for one room or direct context, separated by the
 * recorder source and live conversation generation that actually produced it. */
export async function readLines(
	kind: "room" | "direct",
	directory: string,
	conversation: string,
): Promise<StoredGeneration[]> {
	const selected = targetSlot;
	const releaseRead = holdTargetSlot(selected);
	try {
		await writes;
		const archived = await selected.target.read(kind, directory, conversation);
		const byGeneration = new Map<string, StoredGeneration>();
		for (const record of archived) {
			if (record.kind !== "line" || record.state === "withdrawn") continue;
			const key = `${record.source}\u0000${record.generation}`;
			let group = byGeneration.get(key);
			if (group === undefined) {
				const release = holdTargetSlot(selected);
				group = {
					source: record.source,
					generation: record.generation,
					keeper: selected.target.keeper,
					lines: [],
					readAttachment: (line, index, onProgress) =>
						withTarget(selected, (target) => target.attachment(line, index, onProgress)),
					release,
				};
				byGeneration.set(key, group);
			}
			group.lines.push({
				from: record.from,
				text: record.text,
				mine: record.mine,
				at: record.at,
				attachments: record.attachments,
				archive: record,
			});
		}
		const groups = [...byGeneration.values()];
		for (const group of groups) group.lines.sort((a, b) => a.at - b.at);
		groups.sort((a, b) => (a.lines[0]?.at ?? 0) - (b.lines[0]?.at ?? 0));
		return groups;
	} finally {
		releaseRead();
	}
}
