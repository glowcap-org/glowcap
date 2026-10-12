import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
// One reader owns the selected archive. File sources retain that exact reader.
// Changing selection never retargets an already displayed record.
import type { RoomsManagedArchive } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { directHistoryId } from "../../application.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { AttachedSessionFiles, HeldFile } from "../attached_files.ts";
import type { PresentedFile } from "./files.ts";
import type { ArchiveLine, ArchiveRecord } from "../../../../lib/archive/protocol.ts";
import { MAX_ARCHIVE_READ, MAX_ARCHIVE_RECORDS } from "../../../../lib/archive/limits.ts";
import { conversationIdentity, type WorkspaceSnapshot } from "./model.ts";
import { projectAttachedHistoryRead } from "../history_reconciliation.ts";
import { convByPersistId, setArchiveTarget, toast } from "../../store.ts";
import type { ArchiveTargetView } from "../../archive_model.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

export class ArchiveSource {
	readonly reader: RoomsManagedArchive;
	#references = 1;
	constructor(reader: RoomsManagedArchive) {
		this.reader = reader;
	}
	release(): void {
		if (--this.#references === 0) this.reader.free();
	}
	file(record: ArchiveLine, index: number): HeldFile {
		this.#references++;
		const stop = new AbortController();
		let released = false;
		return {
			mime: record.attachments[index].mime,
			durable: true,
			fetch: (progress) => this.reader.openAttachment(JSON.stringify(record), index, progress, stop.signal),
			release: () => {
				if (!released) {
					released = true;
					stop.abort();
					this.release();
				}
			},
		};
	}
}
export class ManagedHistory {
	readonly #page: RoomsPageContext;
	readonly #session: ManagedRoomsSession;
	readonly #report: (source: string, error: unknown) => void;
	#files: AttachedSessionFiles<PresentedFile> | null = null;
	#source: ArchiveSource | null = null;
	#device: ArchiveSource | null = null;
	#selection: string | null = null;
	#running: Promise<void> | null = null;
	#stop: (() => void) | null = null;
	#dirty = false;
	#topology = "";
	#closed = false;
	#epoch = 0;
	#unavailable: string | null = null;
	readonly #hydrated = new Map<string, string>();
	constructor(
		page: RoomsPageContext,
		session: ManagedRoomsSession,
		report: (source: string, error: unknown) => void,
	) {
		this.#page = page;
		this.#session = session;
		this.#report = report;
	}
	get reader(): RoomsManagedArchive | null {
		return this.#source?.reader ?? null;
	}
	get source(): ArchiveSource | null {
		return this.#source;
	}
	unavailable(key: string): void {
		const current = this.#session.current;
		if (this.#closed || current?.intent.archive !== key || !this.#session.permits("readArchive")) return;
		this.#epoch++;
		this.#hydrated.clear();
		this.#target(current, "unavailable", managedText.archiveUnavailable);
		if (this.#unavailable !== key) toast(this.#page.projection, "failure", managedText.archiveUnavailable);
		this.#unavailable = key;
	}
	bindFiles(files: AttachedSessionFiles<PresentedFile>): void {
		this.#files = files;
	}
	start(): void {
		this.#stop = this.#session.subscribe(() => this.#changed());
		this.refresh();
	}
	#identity(): string {
		const snapshot = this.#session.current;
		if (snapshot == null || !this.#readable(snapshot)) return "unavailable";
		return JSON.stringify([
			this.#sourceIdentity(snapshot),
			snapshot.intent.conversations.map((row) => conversationIdentity(row)),
		]);
	}
	#readable(snapshot: WorkspaceSnapshot): boolean {
		return this.#session.permits("history") ||
			(snapshot.intent.archive != null && this.#session.permits("readArchive"));
	}
	#sourceIdentity(snapshot: WorkspaceSnapshot): string {
		return JSON.stringify([
			snapshot.intent.archive,
			snapshot.intent.historyErasure,
			this.#session.permits("history"),
			this.#session.permits("readArchive"),
			this.#session.permits("readFile"),
		]);
	}
	#target(snapshot: WorkspaceSnapshot, status: "connecting" | "connected" | "unavailable", error = ""): void {
		if (snapshot.intent.archive != null && !this.#session.permits("readArchive")) {
			status = "unavailable";
			error = managedText.archiveReadPermission;
		}
		const target: ArchiveTargetView = snapshot.intent.archive == null
			? { kind: "owned" }
			: { kind: "peer", status, label: managedText.archivePeer, error };
		setArchiveTarget(this.#page.projection, target);
	}
	#changed(): void {
		const topology = this.#identity();
		if (topology === this.#topology) return;
		this.#schedule();
	}
	refresh(): Promise<void> {
		this.#epoch++;
		this.#hydrated.clear();
		return this.#schedule();
	}
	#schedule(): Promise<void> {
		if (this.#closed) return Promise.reject(new Error("This history reader is closed"));
		this.#topology = this.#identity();
		this.#dirty = true;
		if (this.#running != null) return this.#running;
		this.#running = this.#read().catch((error) => {
			this.#topology = "";
			this.#report(managedText.workspaceHistory, error);
			throw error;
		}).finally(() => {
			this.#running = null;
		});
		// Observation and gap callbacks report failures here. Explicit retry
		// callers receive that same failure and can keep their recovery control.
		void this.#running.catch(() => {
			// best-effort: the history reporter and explicit retry caller already own this failure.
		});
		return this.#running;
	}
	async #read(): Promise<void> {
		while (this.#dirty && !this.#closed) {
			this.#dirty = false;
			const snapshot = this.#session.current;
			const epoch = this.#epoch;
			if (snapshot == null || !this.#readable(snapshot)) {
				if (snapshot != null) this.#target(snapshot, "unavailable");
				this.#source?.release();
				this.#device?.release();
				this.#device = null;
				this.#source = null;
				this.#selection = null;
				this.#hydrated.clear();
				continue;
			}
			const files = this.#session.permits("readFile");
			const peer = snapshot.intent.archive != null && this.#session.permits("readArchive");
			const selection = this.#sourceIdentity(snapshot);
			if (this.#source == null || selection !== this.#selection) {
				this.#target(snapshot, "connecting");
				let reader: RoomsManagedArchive;
				let device: RoomsManagedArchive | null = null;
				try {
					reader = peer
						? await this.#session.workspace.selectedArchive(files)
						: await this.#session.workspace.deviceHistory(files);
					if (peer && this.#session.permits("history")) {
						try {
							device = await this.#session.workspace.deviceHistory(files);
						} catch (error) {
							reader.free();
							throw error;
						}
					}
				} catch (error) {
					const current = this.#session.current;
					if (this.#closed) return;
					if (current == null || selection !== this.#sourceIdentity(current)) {
						this.#dirty = true;
						continue;
					}
					this.#target(snapshot, "unavailable", refusalText(error));
					throw error;
				}
				if (this.#closed) {
					reader.free();
					device?.free();
					return;
				}
				const current = this.#session.current;
				if (
					current == null || !this.#readable(current) || selection !== this.#sourceIdentity(current)
				) {
					reader.free();
					device?.free();
					this.#dirty = true;
					continue;
				}
				this.#source?.release();
				this.#device?.release();
				this.#device = null;
				this.#source = new ArchiveSource(reader);
				this.#device = device == null ? null : new ArchiveSource(device);
				this.#selection = selection;
				this.#hydrated.clear();
			}
			const source = this.#source;
			const device = this.#device;
			const ids = new Set(snapshot.intent.conversations.map((row) => row.id));
			for (const id of this.#hydrated.keys()) if (!ids.has(id)) this.#hydrated.delete(id);
			const failures: unknown[] = [];
			let verified = false;
			for (const row of snapshot.intent.conversations) {
				const identity = conversationIdentity(row);
				if (this.#hydrated.get(row.id) === identity) continue;
				const records: ArchiveRecord[] = [];
				let after = "0";
				let stale = false;
				const original = convByPersistId(this.#page.projection, row.id);
				if (original == null) continue;
				const fresh = () => {
					const current = this.#session.current;
					const selected = current?.intent.conversations.find((entry) => entry.id === row.id);
					return !this.#closed && epoch === this.#epoch &&
						current != null && this.#readable(current) && selection === this.#sourceIdentity(current) &&
						selected != null &&
						identity === conversationIdentity(selected) &&
						convByPersistId(this.#page.projection, row.id)?.key === original.key;
				};
				projectAttachedHistoryRead(this.#page, original.key, { phase: "loading" }, this.#files);
				try {
					const filter = JSON.stringify({
						source: null,
						generation: null,
						kind: "line",
						conversationKind: row.kind,
						directory: row.directory,
						conversation: row.kind === "direct" && row.introduction != null
							? directHistoryId(row.directory, row.introduction.registration)
							: row.id,
						digest: null,
					});
					// One bounded view spine identifies each supplying reader. Files
					// capture that reader synchronously; no winner table survives here.
					const keepers = new Map<ArchiveRecord, ArchiveSource>();
					if (device != null) {
						const view: { records: { record: ArchiveRecord; keeper: number }[] } = await source.reader
							.readTogether(device.reader, filter);
						if (!fresh()) {
							this.#dirty = !this.#closed;
							break;
						}
						for (const winner of view.records) {
							records.push(winner.record);
							keepers.set(winner.record, winner.keeper === 0 ? source : device);
						}
					} else {
						while (records.length < MAX_ARCHIVE_RECORDS) {
							const page: { next: string; more: boolean; records: { record: ArchiveRecord }[] } =
								await source.reader.read(filter, after, MAX_ARCHIVE_READ);
							if (!fresh()) {
								stale = true;
								this.#dirty = !this.#closed;
								break;
							}
							for (const { record } of page.records) records.push(record);
							if (
								records.length > MAX_ARCHIVE_RECORDS ||
								(page.more && records.length === MAX_ARCHIVE_RECORDS)
							) {
								throw new Error("The archive exceeded its declared record bound");
							}
							if (!page.more) break;
							if (page.records.length === 0) {
								throw new Error("The archive returned an empty continuation page");
							}
							if (BigInt(page.next) <= BigInt(after)) {
								throw new Error("The archive cursor did not advance");
							}
							after = page.next;
						}
					}
					if (stale) break;
					projectAttachedHistoryRead(
						this.#page,
						original.key,
						{
							phase: "ready",
							records,
							local: !peer || device != null,
							peer,
						},
						this.#files,
						(record, index) => (keepers.get(record) ?? source).file(record, index),
					);
					this.#hydrated.set(row.id, identity);
					verified = true;
				} catch (error) {
					if (!fresh()) {
						this.#dirty = !this.#closed;
						break;
					}
					projectAttachedHistoryRead(this.#page, original.key, {
						phase: "unavailable",
						error: refusalText(error),
					}, this.#files);
					this.#target(snapshot, "unavailable", refusalText(error));
					failures.push(error);
				}
			}
			if (failures.length !== 0) {
				throw new AggregateError(failures, "Workspace conversation history is unavailable");
			}
			const current = this.#session.current;
			if (
				this.#closed || epoch !== this.#epoch || current == null || !this.#readable(current) ||
				selection !== this.#sourceIdentity(current)
			) {
				this.#dirty = !this.#closed;
				continue;
			}
			if (this.#unavailable !== snapshot.intent.archive || verified) {
				this.#unavailable = null;
				this.#target(snapshot, "connected");
			}
		}
	}
	async close(): Promise<void> {
		this.#closed = true;
		this.#stop?.();
		this.#stop = null;
		await this.#running?.catch(() => {
			// tolerant: a failed read is reported and holds no active call.
			// Shutdown releases both exact archive readers.
		});
		this.#source?.release();
		this.#device?.release();
		this.#source = null;
		this.#device = null;
	}
}
