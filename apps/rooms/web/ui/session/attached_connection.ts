// Reconnecting browser transport for one durable Rooms session capability.

import { retainCleanupFailures, retainSecondaryFailure, secondaryFailureCount, type Session } from "@pancake/runtime";
import {
	type RoomsOperationsSnapshot,
	RoomsSessionClient,
	type RoomsSessionFacet,
	type RoomsSessionGrantView,
	type RoomsSessionLineEvent,
	type RoomsSessionSnapshot,
} from "../../../lib/rooms_session.ts";
import type { Attachment, AttachmentSource } from "../../../lib/attachment.ts";
import type { ArchiveRecord } from "../../../lib/archive.ts";
import type { OperatorCategory, OperatorPage, OperatorRetireBatch, OperatorSnapshot } from "../../../lib/operator.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import { dial, roomsAddress, roomsSturdyrefForSession, roomsSturdyrefLocator } from "../../../lib/locator.ts";
import { bootRuntime } from "../net/runtime_boot.ts";
import { AttachedRoomsController } from "./attached.ts";
import type { AttachedRoomsRemote } from "./remote.ts";
import { answerWithin } from "../../../lib/deadline.ts";

const RECONNECT_FLOOR_MS = 500;
const RECONNECT_CEILING_MS = 5_000;
const ATTACHED_OPEN_TIMEOUT_MS = 15_000;

interface ActiveConnection {
	session: Session;
	client: RoomsSessionClient;
	serving: Promise<void>;
}

interface ServingOutcome {
	error: Error;
}

function connectionError(error: unknown): Error {
	return error instanceof Error ? error : new Error(String(error));
}

function observeServing(serving: Promise<void>): Promise<ServingOutcome> {
	return serving.then(
		() => ({ error: new Error("the shared Rooms session connection closed") }),
		(error) => ({ error: connectionError(error) }),
	);
}

/** Establishment succeeds only if the first complete session snapshot wins the
 * race against transport termination. */
export async function firstAttachedSnapshot(
	watching: Promise<RoomsSessionSnapshot>,
	ended: Promise<ServingOutcome>,
): Promise<RoomsSessionSnapshot> {
	const first = await Promise.race([
		ended.then(({ error }) => ({ kind: "ended" as const, error })),
		watching.then((snapshot) => ({ kind: "snapshot" as const, snapshot })),
	]);
	if (first.kind === "ended") throw first.error;
	return first.snapshot;
}

class ReconnectingAttachedRemote implements AttachedRoomsRemote {
	readonly #sturdyref: string;
	#active: ActiveConnection | null = null;
	#snapshot: RoomsSessionSnapshot | null = null;
	#changed: ((snapshot: RoomsSessionSnapshot) => void) | null = null;
	#event: ((event: RoomsSessionLineEvent) => void) | null = null;
	#operationsChanged: ((scope: string) => void) | null = null;
	#timer: ReturnType<typeof setTimeout> | null = null;
	#delay = RECONNECT_FLOOR_MS;
	#closed = false;
	#connecting: Promise<RoomsSessionSnapshot> | null = null;
	#generation: symbol | null = null;

	constructor(sturdyref: string) {
		this.#sturdyref = sturdyref;
	}

	async watch(
		changed: (snapshot: RoomsSessionSnapshot) => void,
		event: (event: RoomsSessionLineEvent) => void,
		operationsChanged: (scope: string) => void,
	): Promise<RoomsSessionSnapshot> {
		this.#changed = changed;
		this.#event = event;
		this.#operationsChanged = operationsChanged;
		return await this.#connect();
	}

	snapshot(): Promise<RoomsSessionSnapshot> {
		return this.#client().snapshot();
	}

	command(operationId: string, baseRevision: number, name: string, args: string[]): Promise<number> {
		return this.#client().command(operationId, baseRevision, name, args);
	}

	publishPeeredRoom(operationId: string, baseRevision: number, intent: unknown): Promise<number> {
		return this.#client().publishPeeredRoom(operationId, baseRevision, intent);
	}

	revokePeeredRoom(operationId: string, baseRevision: number, id: string): Promise<number> {
		return this.#client().revokePeeredRoom(operationId, baseRevision, id);
	}

	setTyping(conversationId: string, on: boolean): Promise<void> {
		return this.#client().setTyping(conversationId, on);
	}

	editLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		text: string,
	): Promise<number> {
		return this.#client().editLine(operationId, baseRevision, conversationId, lineId, text);
	}

	withdrawLine(operationId: string, baseRevision: number, conversationId: string, lineId: number): Promise<number> {
		return this.#client().withdrawLine(operationId, baseRevision, conversationId, lineId);
	}

	replace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return this.#client().replace(operationId, baseRevision, checkpoint);
	}

	adoptWorkspace(operationId: string, baseRevision: number, checkpoint: RoomsSessionState): Promise<number> {
		return this.#client().adoptWorkspace(operationId, baseRevision, checkpoint);
	}

	sendFiles(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	): Promise<number> {
		return this.#client().sendFiles(operationId, baseRevision, conversationId, caption, files);
	}

	refileLine(
		operationId: string,
		baseRevision: number,
		conversationId: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		files: AttachmentSource[],
	): Promise<number> {
		return this.#client().refileLine(operationId, baseRevision, conversationId, lineId, caption, keep, files);
	}

	readHistory(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		return this.#client().readHistory(kind, directory, conversation);
	}

	operatorSnapshot(scope: string, query = ""): Promise<OperatorSnapshot> {
		return this.#client().operatorSnapshot(scope, query);
	}

	operatorPage(scope: string, category: OperatorCategory, cursor: number, query = ""): Promise<OperatorPage> {
		return this.#client().operatorPage(scope, category, cursor, query);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
	): Promise<OperatorRetireBatch> {
		return this.#client().operatorRetireMatching(scope, category, query, limit);
	}

	operationsSnapshot(
		scope: string,
		capability: RoomsOperationsSnapshot["capability"],
	): Promise<RoomsOperationsSnapshot> {
		return this.#client().operationsSnapshot(scope, capability);
	}

	shareArchiveHistory(conversationId: string): Promise<void> {
		return this.#client().shareArchiveHistory(conversationId);
	}

	readArchiveShare(id: string): ReturnType<RoomsSessionClient["readArchiveShare"]> {
		return this.#client().readArchiveShare(id);
	}

	dropArchiveShare(id: string): Promise<void> {
		return this.#client().dropArchiveShare(id);
	}

	fetchAttachment(attachment: Attachment, onProgress?: (got: number) => void): Promise<Uint8Array> {
		return this.#client().fetchAttachment(attachment, onProgress);
	}

	fetchArchivedAttachment(
		record: Extract<ArchiveRecord, { kind: "line" }>,
		index: number,
		onProgress?: (got: number) => void,
	): Promise<Uint8Array> {
		return this.#client().fetchArchivedAttachment(record, index, onProgress);
	}

	releaseAttachment(attachment: Attachment): void {
		this.#client().releaseAttachment(attachment);
	}

	resolveEffect(operationId: string, outcome: "committed" | "abandoned"): Promise<void> {
		return this.#client().resolveEffect(operationId, outcome);
	}

	resumeEffect(operationId: string): Promise<number> {
		return this.#client().resumeEffect(operationId);
	}

	issueGrant(id: string, rights: RoomsSessionFacet, label: string): Promise<RoomsSessionGrantView> {
		return this.#client().issueGrant(id, rights, label);
	}

	revokeGrant(id: string): Promise<void> {
		return this.#client().revokeGrant(id);
	}

	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		this.#generation = null;
		if (this.#timer != null) clearTimeout(this.#timer);
		this.#timer = null;
		const connecting = this.#connecting;
		if (connecting != null) {
			try {
				await connecting;
			} catch (error) {
				// Closing supersedes this reconnect. #open owns and awaits any
				// transport resources it acquired before rejecting.
				if (secondaryFailureCount(error) > 0) throw error;
			}
		}
		const active = this.#active;
		this.#active = null;
		if (active == null) return;
		let failure: unknown | null = null;
		try {
			await active.session.close();
		} catch (error) {
			failure = error;
		}
		try {
			await active.serving;
		} catch (error) {
			failure = failure == null ? error : retainSecondaryFailure(failure, error);
		}
		if (failure != null) throw failure;
	}

	#client(): RoomsSessionClient {
		if (this.#active == null) throw new Error("the shared Rooms session is disconnected and reconnecting");
		return this.#active.client;
	}

	#connect(): Promise<RoomsSessionSnapshot> {
		if (this.#closed) return Promise.reject(new Error("this attached Rooms connection is closed"));
		if (this.#connecting != null) return this.#connecting;
		this.#connecting = this.#open().finally(() => this.#connecting = null);
		return this.#connecting;
	}

	async #open(): Promise<RoomsSessionSnapshot> {
		const generation = Symbol("attached Rooms connection");
		this.#generation = generation;
		const locator = roomsSturdyrefLocator(this.#sturdyref);
		const runtime = await bootRuntime();
		const session = await dial(roomsAddress(locator), runtime);
		const serving = session.serve();
		const ended = observeServing(serving);
		try {
			const capability = await session.enliven(roomsSturdyrefForSession(this.#sturdyref, session));
			const client = new RoomsSessionClient(session, capability);
			const snapshot = await firstAttachedSnapshot(
				client.watch(
					(changed) => {
						if (this.#generation !== generation) return;
						this.#snapshot = changed;
						this.#changed?.(changed);
					},
					(event) => {
						if (this.#generation === generation) this.#event?.(event);
					},
					(scope) => {
						if (this.#generation === generation) this.#operationsChanged?.(scope);
					},
				),
				ended,
			);
			if (this.#closed || this.#generation !== generation) {
				throw new Error("this attached Rooms connection closed while opening");
			}
			const active = { session, client, serving };
			this.#active = active;
			this.#snapshot = snapshot;
			this.#delay = RECONNECT_FLOOR_MS;
			void ended.then(({ error }) => this.#lost(active, error));
			return snapshot;
		} catch (error) {
			if (this.#generation === generation) this.#generation = null;
			throw await retainCleanupFailures(connectionError(error), [() => session.close(), () => serving]);
		}
	}

	#lost(active: ActiveConnection, error: unknown): void {
		if (this.#active !== active) return;
		this.#active = null;
		this.#generation = null;
		void this.#retireLost(active, error);
	}

	async #retireLost(active: ActiveConnection, error: unknown): Promise<void> {
		let failure = error;
		try {
			await active.session.close();
		} catch (cleanup) {
			failure = retainSecondaryFailure(failure, cleanup);
		}
		this.#publishDisconnected(failure);
		this.#schedule();
	}

	#schedule(): void {
		if (this.#closed || this.#timer != null) return;
		const delay = this.#delay;
		this.#delay = Math.min(this.#delay * 2, RECONNECT_CEILING_MS);
		this.#timer = setTimeout(() => {
			this.#timer = null;
			void this.#connect().then(
				(snapshot) => this.#changed?.(snapshot),
				(error) => {
					this.#publishDisconnected(error);
					this.#schedule();
				},
			);
		}, delay);
	}

	#publishDisconnected(error: unknown): void {
		const snapshot = this.#snapshot;
		if (snapshot == null) return;
		const reason = connectionError(error).message;
		const disconnected = {
			...snapshot,
			connectedDirectories: [],
			issues: [
				...snapshot.issues.filter((issue) => issue.subject !== "session"),
				{ subject: "session", reason },
			],
		};
		this.#snapshot = disconnected;
		this.#changed?.(disconnected);
	}
}

export async function connectAttachedRoomsSession(sturdyref: string): Promise<AttachedRoomsController> {
	return await settleAttachedOpening(openAttachedRoomsSession(sturdyref));
}

export async function settleAttachedOpening(
	opening: Promise<AttachedRoomsController>,
	timeoutMs = ATTACHED_OPEN_TIMEOUT_MS,
): Promise<AttachedRoomsController> {
	try {
		return await answerWithin(
			opening,
			"The shared Rooms session did not answer before the attachment deadline.",
			timeoutMs,
		);
	} catch (error) {
		void opening.then(
			(controller) =>
				controller.close().catch((cleanup) => {
					console.error(
						`rooms: a late attached-session connection could not be retired: ${
							connectionError(cleanup).message
						}`,
					);
				}),
			() => {},
		);
		throw error;
	}
}

async function openAttachedRoomsSession(sturdyref: string): Promise<AttachedRoomsController> {
	const remote = new ReconnectingAttachedRemote(sturdyref);
	const controller = new AttachedRoomsController(remote, () => remote.close());
	await controller.start();
	return controller;
}
