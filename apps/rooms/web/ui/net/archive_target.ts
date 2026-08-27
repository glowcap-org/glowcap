// The archive peer this tab chooses as its recorder.
//
// The presentation store never receives the sturdyref, Session, or Ref. This
// module owns all three, validates a candidate by making a bounded read, and
// swaps the history seam only after the candidate has proved the contract.

import { type Ref, retainCleanupFailures, type Session } from "@pancake/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveFilter,
	type ArchiveLine,
	type ArchiveRecord,
	narrowArchive,
	putArchive,
	putArchiveWithAttachments,
	readAllArchiveRecords,
	readArchive,
	readArchiveAttachment,
} from "../../../lib/archive.ts";
import { type AttachmentSource, fetchBlob } from "../../../lib/attachment.ts";
import {
	activateHistoryArchiveTarget,
	type HistoryArchiveTarget,
	holdHistoryArchiveTarget,
	settleHistoryWrites,
	unavailableHistoryArchiveTarget,
	useDeviceHistoryArchive,
} from "../history.ts";
import * as store from "../store.ts";
import { rememberedWorkspaceArchivePeer, setRememberedWorkspaceArchivePeer } from "../workspace_state.ts";
import { reason } from "./common.ts";
import { bootRuntime } from "./runtime_boot.ts";
import type { Live } from "./live.ts";
import { parseRoomsSturdyref, roomsSturdyrefForSession } from "../../../lib/locator.ts";

function lineFilter(kind: "room" | "direct", directory: string, conversation: string): ArchiveFilter {
	return {
		...ALL_ARCHIVE_RECORDS,
		kind: "line",
		conversationKind: kind,
		directory,
		conversation,
	};
}

class RemoteHistoryArchive implements HistoryArchiveTarget {
	readonly kind = "peer" as const;
	readonly keeper: string;
	readonly #session: Session;
	readonly #archive: Ref;
	#failed = false;
	#onUnavailable: ((why: string) => void) | null = null;

	constructor(session: Session, archive: Ref, keeper: string) {
		this.#session = session;
		this.#archive = archive;
		this.keeper = keeper;
	}

	watchFailures(onUnavailable: (why: string) => void): void {
		this.#onUnavailable = onUnavailable;
	}

	async #use<T>(operation: () => Promise<T>): Promise<T> {
		if (this.#failed) throw new Error("the selected archive peer is unavailable");
		try {
			return await operation();
		} catch (error) {
			this.#failed = true;
			this.#onUnavailable?.(reason(error));
			throw error;
		}
	}

	put(record: ArchiveLine, attachments: readonly AttachmentSource[] = []) {
		return this.#use(() =>
			attachments.length === 0
				? putArchive(this.#session, this.#archive, record)
				: putArchiveWithAttachments(this.#session, this.#archive, record, [...attachments])
		);
	}

	read(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#use(() => this.#read(kind, directory, conversation));
	}

	attachment(record: ArchiveLine, index: number, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return this.#use(async () => {
			const attachment = await readArchiveAttachment(this.#session, this.#archive, record, index);
			if (attachment == null) throw new Error("those archived file bytes are unavailable");
			try {
				return await fetchBlob(this.#session, attachment, onProgress);
			} finally {
				this.#session.release(attachment.blob);
			}
		});
	}

	facet(scope: ArchiveFilter): Promise<PreparedArchiveFacet> {
		return this.#use(async () =>
			heldFacet(this.#session, await narrowArchive(this.#session, this.#archive, scope))
		);
	}

	async #read(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		const filter = lineFilter(kind, directory, conversation);
		return await readAllArchiveRecords(this.#session, this.#archive, filter);
	}

	async retire(): Promise<void> {
		await this.#session.close();
	}
}

interface Candidate {
	readonly target: RemoteHistoryArchive;
	readonly label: string;
}

function labelOf(sturdyref: string): string {
	const locator = parseRoomsSturdyref(sturdyref).locator;
	const short = locator.designator.length > 16 ? `${locator.designator.slice(0, 16)}…` : locator.designator;
	return `${locator.transport} peer ${short}`;
}

async function openCandidate(sturdyref: string): Promise<Candidate> {
	const parsed = parseRoomsSturdyref(sturdyref);
	const runtime = await bootRuntime();
	const session = await runtime.connect(parsed.locator);
	try {
		const archive = await session.enliven(roomsSturdyrefForSession(sturdyref, session));
		const target = new RemoteHistoryArchive(session, archive, labelOf(sturdyref));
		// A sturdyref proves authority, not interface. One bounded read makes sure
		// Settings does not report an arbitrary two-verb object as an archive.
		await readArchive(session, archive, ALL_ARCHIVE_RECORDS, 0, 1);
		return { target, label: target.keeper };
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.close()]);
	}
}

let desiredLink: string | null = null;
let desiredRemember = false;
let activePeer: RemoteHistoryArchive | null = null;

export interface PreparedArchiveFacet {
	readonly ref: Ref;
	release(): void;
}

function heldFacet(session: Session, ref: Ref): PreparedArchiveFacet {
	let held = true;
	return {
		ref,
		release() {
			if (!held) return;
			held = false;
			try {
				session.release(ref);
			} catch (error) {
				store.noteTrouble("archive share release", reason(error));
			}
		},
	};
}

/** Mint the selected recorder's read-only facet for one direct conversation.
 * An unavailable peer refuses here; selection never falls back to the tab. */
export async function prepareDirectArchiveFacet(home: Live, conversation: string): Promise<PreparedArchiveFacet> {
	await settleHistoryWrites();
	const scope: ArchiveFilter = {
		...ALL_ARCHIVE_RECORDS,
		kind: "line",
		conversationKind: "direct",
		directory: home.id,
		conversation,
	};
	if (desiredLink !== null) {
		if (activePeer === null) throw new Error("the selected archive peer is unavailable");
		const selected = holdHistoryArchiveTarget();
		if (selected.target !== activePeer) {
			selected.release();
			throw new Error("the archive recorder is changing; try sharing again");
		}
		try {
			const facet = await activePeer.facet(scope);
			let held = true;
			return {
				ref: facet.ref,
				release() {
					if (!held) return;
					held = false;
					try {
						facet.release();
					} finally {
						selected.release();
					}
				},
			};
		} catch (error) {
			selected.release();
			throw error;
		}
	}
	return heldFacet(home.dir.session, await narrowArchive(home.dir.session, home.archive, scope));
}

async function adopt(sturdyref: string, remember: boolean): Promise<string> {
	let candidate: Candidate;
	try {
		candidate = await openCandidate(sturdyref);
	} catch (error) {
		return reason(error);
	}
	if (!setRememberedWorkspaceArchivePeer(remember ? sturdyref : null)) {
		await candidate.target.retire();
		return "This browser refused to update the saved archive capability.";
	}
	await activateHistoryArchiveTarget(candidate.target);
	desiredLink = sturdyref;
	desiredRemember = remember;
	activePeer = candidate.target;
	candidate.target.watchFailures((why) => {
		if (activePeer !== candidate.target) return;
		store.setArchiveTarget({
			kind: "peer",
			status: "unavailable",
			label: candidate.label,
			remembered: remember,
			error: why,
		});
		store.toast(
			"failure",
			"The archive peer is unavailable. Rooms will not copy history into this browser; reconnect it or choose this browser in Settings.",
		);
	});
	store.setArchiveTarget({
		kind: "peer",
		status: "connected",
		label: candidate.label,
		remembered: remember,
		error: "",
	});
	return "";
}

/** Select a pasted whole-archive sturdyref. A failed candidate leaves the
 * current recorder untouched. */
export async function takeArchivePeer(pasted: string, remember = false): Promise<string> {
	const sturdyref = pasted.trim();
	if (sturdyref === "") return "Paste an archive sturdyref first.";
	return await adopt(sturdyref, remember);
}

/** Restore only an explicitly remembered bearer. While it is unreachable,
 * writes decline instead of silently forking into the device store. */
export async function restoreArchivePeer(): Promise<void> {
	const sturdyref = rememberedWorkspaceArchivePeer();
	if (sturdyref === null || sturdyref.trim() === "") return;
	desiredLink = sturdyref;
	desiredRemember = true;
	let label = "the remembered archive peer";
	try {
		label = labelOf(sturdyref);
	} catch {
		// The connection attempt below owns the actionable parse error.
	}
	store.setArchiveTarget({ kind: "peer", status: "connecting", label, remembered: true, error: "" });
	await activateHistoryArchiveTarget(unavailableHistoryArchiveTarget(label));
	const why = await adopt(sturdyref, true);
	if (why !== "") {
		store.setArchiveTarget({ kind: "peer", status: "unavailable", label, remembered: true, error: why });
	}
}

export async function retryArchivePeer(): Promise<string> {
	if (desiredLink === null) return "No archive peer is selected.";
	return await adopt(desiredLink, desiredRemember);
}

export async function useDeviceArchive(): Promise<void> {
	if (!setRememberedWorkspaceArchivePeer(null)) {
		throw new Error("This browser refused to remove the saved archive capability.");
	}
	desiredLink = null;
	desiredRemember = false;
	activePeer = null;
	await useDeviceHistoryArchive();
	store.setArchiveTarget({ kind: "device" });
}
