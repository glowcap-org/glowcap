// The archive peer this tab chooses as its recorder.
//
// The presentation store never receives the sturdyref, Session, or Ref. This
// module owns all three, validates a candidate by making a bounded read, and
// swaps the history seam only after the candidate has proved the contract.

import * as store from "../store.ts";
import { type Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
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
} from "../../../lib/archive/protocol.ts";
import { issueArchiveShare, listArchiveShares, revokeArchiveShare } from "../../../lib/archive/client.ts";
import { parseRoomsSturdyref } from "../../../lib/locator.ts";
import { type AttachmentSource, fetchBlob } from "../../../lib/attachment.ts";
import {
	activateHistoryArchiveTarget,
	type HistoryArchiveTarget,
	holdHistoryArchiveTarget,
	settleHistoryWrites,
	unavailableHistoryArchiveTarget,
	useDeviceHistoryArchive,
} from "../history.ts";
import { rememberedWorkspaceArchivePeer, setRememberedWorkspaceArchivePeer } from "../workspace_state.ts";
import { reason } from "./common.ts";
import { type Live } from "./live.ts";
import { bootRuntime } from "./runtime_boot.ts";
import type { RoomsPageContext } from "../page.ts";
import { ARCHIVE_CANNOT_MINT_SHARE } from "../../../lib/archive/durable_protocol.ts";

function lineFilter(kind: "room" | "direct", directory: string, conversation: string): ArchiveFilter {
	return {
		...ALL_ARCHIVE_RECORDS,
		kind: "line",
		conversationKind: kind,
		directory,
		conversation,
	};
}

export interface ArchivePeerTarget extends HistoryArchiveTarget {
	readonly kind: "peer";
	facet(scope: ArchiveFilter): Promise<PreparedArchiveFacet>;
	issueShare(id: string, label: string, scope: ArchiveFilter): Promise<string>;
	revokeShare(id: string): Promise<boolean>;
	listShares(): Promise<import("../../../lib/archive/facet.ts").ArchiveDurableShareView[]>;
	watchFailures(onUnavailable: (why: string) => void): void;
}

export class RemoteHistoryArchive implements ArchivePeerTarget {
	readonly kind = "peer" as const;
	readonly keeper: string;
	readonly #page: RoomsPageContext;
	readonly #session: Session;
	readonly #archive: Ref;
	#failed = false;
	#onUnavailable: ((why: string) => void) | null = null;

	constructor(page: RoomsPageContext, session: Session, archive: Ref, keeper: string) {
		this.#page = page;
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
			// A record refusal or missing blob is local to that operation. Only the
			// session ending makes the selected peer unavailable for every later use.
			if (!this.#session.sessionOpen) {
				this.#failed = true;
				this.#onUnavailable?.(reason(error));
			}
			throw error;
		}
	}

	put(record: ArchiveRecord, attachments: readonly AttachmentSource[] = []) {
		return this.#use(() =>
			record.kind === "line" && attachments.length > 0
				? putArchiveWithAttachments(this.#session, this.#archive, record, [...attachments])
				: putArchive(this.#session, this.#archive, record)
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
			heldFacet(this.#page, this.#session, await narrowArchive(this.#session, this.#archive, scope))
		);
	}

	issueShare(id: string, label: string, scope: ArchiveFilter): Promise<string> {
		return this.#use(() => issueArchiveShare(this.#session, this.#archive, id, label, scope));
	}

	revokeShare(id: string): Promise<boolean> {
		return this.#use(() => revokeArchiveShare(this.#session, this.#archive, id));
	}

	listShares(): Promise<import("../../../lib/archive/facet.ts").ArchiveDurableShareView[]> {
		return this.#use(() => listArchiveShares(this.#session, this.#archive));
	}

	async #read(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		const filter = lineFilter(kind, directory, conversation);
		return await readAllArchiveRecords(this.#session, this.#archive, filter);
	}

	async retire(): Promise<void> {
		await this.#session.close();
	}
}

export interface ArchiveCandidate {
	readonly target: ArchivePeerTarget;
	readonly label: string;
}

function labelOf(sturdyref: string): string {
	const locator = parseRoomsSturdyref(sturdyref).locator;
	const short = locator.designator.length > 16 ? `${locator.designator.slice(0, 16)}…` : locator.designator;
	return `${locator.transport} peer ${short}`;
}

async function openCandidate(page: RoomsPageContext, sturdyref: string): Promise<ArchiveCandidate> {
	const parsed = parseRoomsSturdyref(sturdyref);
	const runtime = await bootRuntime(page);
	const session = await runtime.connect(parsed.locator);
	try {
		const archive = await session.enliven(sturdyref);
		const target = new RemoteHistoryArchive(page, session, archive, labelOf(sturdyref));
		// A sturdyref proves authority, not interface. One bounded read makes sure
		// Settings does not report an arbitrary two-verb object as an archive.
		await readArchive(session, archive, ALL_ARCHIVE_RECORDS, 0, 1);
		return { target, label: target.keeper };
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.close()]);
	}
}

export interface PreparedArchiveFacet {
	readonly ref: Ref;
	release(): void;
}

function heldFacet(page: RoomsPageContext, session: Session, ref: Ref): PreparedArchiveFacet {
	let held = true;
	return {
		ref,
		release() {
			if (!held) return;
			held = false;
			try {
				session.release(ref);
			} catch (error) {
				store.noteTrouble(page.projection, "archive share release", reason(error));
			}
		},
	};
}

/** Open an archive sturdyref through this page's wasm runtime. */
export function openArchivePeer(page: RoomsPageContext): (sturdyref: string) => Promise<ArchiveCandidate> {
	return (sturdyref) => openCandidate(page, sturdyref);
}

/** One browser workspace's archive selection and transition owner. Candidate
 * validation, target activation, selection metadata, and retirement serialize
 * as one act, so two Settings submissions cannot describe different peers. */
export class ArchiveTargetController {
	readonly #page: RoomsPageContext;
	readonly #openCandidate: (sturdyref: string) => Promise<ArchiveCandidate>;
	#desiredLink: string | null = null;
	#desiredRemember = false;
	#activePeer: ArchivePeerTarget | null = null;
	#transitions: Promise<void> = Promise.resolve();

	constructor(page: RoomsPageContext, open: (sturdyref: string) => Promise<ArchiveCandidate>) {
		this.#page = page;
		this.#openCandidate = open;
	}

	#serialize<T>(work: () => Promise<T>): Promise<T> {
		const result = this.#transitions.then(work, work);
		this.#transitions = result.then(() => {}, () => {});
		return result;
	}

	/** Mint the selected recorder's read-only facet for one archive scope.
	 * An unavailable peer refuses here; selection never falls back to the tab. */
	async prepareArchiveFacet(home: Live, scope: ArchiveFilter): Promise<PreparedArchiveFacet> {
		await this.#transitions;
		await settleHistoryWrites(this.#page);
		if (this.#desiredLink !== null) {
			const active = this.#activePeer;
			if (active === null) throw new Error("the selected archive peer is unavailable");
			const selected = holdHistoryArchiveTarget(this.#page);
			if (selected.target !== active) {
				selected.release();
				throw new Error("the archive recorder is changing. Try sharing again");
			}
			try {
				const facet = await active.facet(scope);
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
		return heldFacet(this.#page, home.dir.session, await narrowArchive(home.dir.session, home.archive, scope));
	}

	async #adopt(sturdyref: string, remember: boolean): Promise<string> {
		let candidate: ArchiveCandidate;
		try {
			candidate = await this.#openCandidate(sturdyref);
		} catch (error) {
			return reason(error);
		}
		if (!setRememberedWorkspaceArchivePeer(this.#page, remember ? sturdyref : null)) {
			await candidate.target.retire();
			return "This browser refused to update the saved archive capability.";
		}
		await activateHistoryArchiveTarget(this.#page, candidate.target);
		this.#desiredLink = sturdyref;
		this.#desiredRemember = remember;
		this.#activePeer = candidate.target;
		candidate.target.watchFailures((why) => {
			if (this.#activePeer !== candidate.target) return;
			store.setArchiveTarget(this.#page.projection, {
				owner: "browser",
				kind: "peer",
				status: "unavailable",
				label: candidate.label,
				remembered: remember,
				error: why,
			});
			store.toast(
				this.#page.projection,
				"failure",
				"The archive peer is unavailable. Rooms will not copy history into this browser. Reconnect it, or choose this browser in Settings.",
			);
		});
		store.setArchiveTarget(this.#page.projection, {
			owner: "browser",
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
	takeArchivePeer(pasted: string, remember = false): Promise<string> {
		const sturdyref = pasted.trim();
		if (sturdyref === "") return Promise.resolve("Paste an archive sturdyref first.");
		return this.#serialize(() => this.#adopt(sturdyref, remember));
	}

	/** Restore only an explicitly remembered bearer. While it is unreachable,
	 * writes decline instead of silently forking into the device store. */
	restoreArchivePeer(): Promise<void> {
		return this.#serialize(async () => {
			const sturdyref = rememberedWorkspaceArchivePeer(this.#page);
			if (sturdyref === null || sturdyref.trim() === "") return;
			this.#desiredLink = sturdyref;
			this.#desiredRemember = true;
			let label = "the remembered archive peer";
			try {
				label = labelOf(sturdyref);
			} catch {
				// The connection attempt below owns the actionable parse error.
			}
			store.setArchiveTarget(this.#page.projection, {
				owner: "browser",
				kind: "peer",
				status: "connecting",
				label,
				remembered: true,
				error: "",
			});
			await activateHistoryArchiveTarget(this.#page, unavailableHistoryArchiveTarget(label));
			const why = await this.#adopt(sturdyref, true);
			if (why !== "") {
				store.setArchiveTarget(this.#page.projection, {
					owner: "browser",
					kind: "peer",
					status: "unavailable",
					label,
					remembered: true,
					error: why,
				});
			}
		});
	}

	retryArchivePeer(): Promise<string> {
		return this.#serialize(() => {
			if (this.#desiredLink === null) return Promise.resolve("No archive peer is selected.");
			return this.#adopt(this.#desiredLink, this.#desiredRemember);
		});
	}

	useDeviceArchive(): Promise<void> {
		return this.#serialize(async () => {
			if (!setRememberedWorkspaceArchivePeer(this.#page, null)) {
				throw new Error("This browser refused to remove the saved archive capability.");
			}
			this.#desiredLink = null;
			this.#desiredRemember = false;
			this.#activePeer = null;
			await useDeviceHistoryArchive(this.#page);
			store.setArchiveTarget(this.#page.projection, { kind: "owned", owner: "browser" });
		});
	}

	issueShare(id: string, label: string, scope: ArchiveFilter): Promise<string> {
		const peer = this.#activePeer;
		if (peer == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return peer.issueShare(id, label, scope);
	}

	revokeShare(id: string): Promise<boolean> {
		const peer = this.#activePeer;
		if (peer == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return peer.revokeShare(id);
	}

	listShares(): Promise<import("../../../lib/archive/facet.ts").ArchiveDurableShareView[]> {
		const peer = this.#activePeer;
		if (peer == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return peer.listShares();
	}

	/** End this page owner's selected peer without changing whether the browser
	 * should remember it for a later page. */
	close(): Promise<void> {
		return this.#serialize(async () => {
			this.#desiredLink = null;
			this.#desiredRemember = false;
			this.#activePeer = null;
			await useDeviceHistoryArchive(this.#page);
		});
	}
}
