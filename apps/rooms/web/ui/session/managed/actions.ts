import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
// Page gestures acquire exact receipt occurrences. Rust executes all effects.
import type {
	RoomsManagedAcquisition,
	RoomsManagedDirectoryAcquisition,
	RoomsManagedOperationsAcquisition,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";
import type { ManagedOperation } from "./operation.ts";
import type { ConversationOpening } from "./openings.ts";
import { acquireDirect } from "./direct.ts";
import { createManagedRoom } from "./create_room.ts";
import { type ActivityPage, type Coordinate, fieldKey, type WorkspaceIntent, type WorkspaceSnapshot } from "./model.ts";
import type { JoinNicknameIntent } from "../../controller/session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import { applicationModule } from "../../application.ts";
import { AcquisitionConflict, MAX_CONFLICT_REPREPARATIONS, submitAcquisition } from "./acquisition.ts";
import { retainedIntentConversation } from "./admission.ts";
import type { OpsCap } from "../../types.ts";
import { CompletedLine } from "./completed_line.ts";

export class OperationsAcquisitionRefused extends Error {
	constructor(readonly failures: readonly { capability: OpsCap; reason: string; advice: string | null }[]) {
		super(managedText.operationsAcquisitionRefused);
	}
}

import { LOCAL_LIMITS } from "./local_gestures.ts";
import { gestureScope } from "./gestures.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { OperationLifecycle } from "./lifecycle.ts";
import { CancellationRecovery } from "./cancellation.ts";

interface AcquisitionRecord {
	intent: string;
	result?: string;
	lifecycle: OperationLifecycle;
	request?: Acquisition;
	task?: Promise<void>;
	completed?: () => Promise<void>;
	signal?: AbortSignal;
	cancellation?: CancellationRecovery;
}

type Acquisition = RoomsManagedAcquisition | RoomsManagedDirectoryAcquisition | RoomsManagedOperationsAcquisition;

/** Only some prepared acquisitions retain their target for re-preparation after a proved conflict. */
function isRepreparable(
	request: Acquisition,
): request is Acquisition & { reprepare(): Promise<Acquisition> } {
	return "reprepare" in request;
}
export class ManagedActions {
	readonly #session: ManagedRoomsSession;
	readonly #acquisitions = new Map<string, AcquisitionRecord>();
	readonly #running = new Set<Promise<unknown>>();
	#stopped = false;
	readonly #gestures = new Map<string, { task: Promise<unknown>; signal?: AbortSignal }>();
	// The activity reader presents one cursor at a time. Keep its completed
	// arrival through projection retry, even after custody acquisition is settled.
	#receivedArrival: string | null = null;
	#importState: string | null = null;
	#importing: Promise<void> | null = null;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	get diagnostics() {
		return [...this.#acquisitions.values()].map((record) => record.lifecycle.inspect());
	}
	get resources() {
		return { acquisitions: this.#acquisitions.size, workers: this.#running.size, gestures: this.#gestures.size };
	}
	get pending(): readonly string[] {
		return [...this.#acquisitions].filter((
			[, record],
		) => (record.request != null || record.lifecycle.outcome === "committed")).map(([id]) => id);
	}
	get recoverable(): readonly string[] {
		return [...this.#acquisitions].filter(([, record]) =>
			(record.request != null || record.lifecycle.outcome === "committed") && record.lifecycle.needsDecision &&
			!record.cancellation?.pending
		)
			.map(([id]) => id);
	}
	/** Only new conversations belong to acquisitions. Keep cancelled results
	 * out of presentation until this owner proves non-admission or departure. */
	get cancelledConversations(): readonly string[] {
		return [...this.#acquisitions.values()].flatMap((record) =>
			record.signal?.aborted && record.result != null ? [record.result] : []
		);
	}
	#acquire(
		id: string,
		prepare: () => Promise<Acquisition>,
		intent = id,
		result?: string,
		signal?: AbortSignal,
		completed?: () => Promise<void>,
	): Promise<void> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const existing = this.#acquisitions.get(id);
		if (existing != null) {
			if (existing.intent !== intent) {
				return Promise.reject(new Error("Recover the original acquisition before changing its contents"));
			}
			return existing.task ?? this.recoverAcquisition(id);
		}
		if (this.#acquisitions.size >= LOCAL_LIMITS.acquisitions) {
			return Promise.reject(new Error("Recover pending acquisitions before preparing another one"));
		}
		const record: AcquisitionRecord = {
			intent,
			result,
			completed,
			signal,
			lifecycle: new OperationLifecycle(id, () => this.#session.acquisitionChanged()),
		};
		this.#acquisitions.set(id, record);
		record.cancellation = new CancellationRecovery(
			signal,
			() =>
				!this.#stopped && record.task == null && this.#acquisitions.get(id) === record &&
				(record.request != null || record.lifecycle.outcome === "committed"),
			() => this.recoverAcquisition(id),
			() => this.#session.acquisitionChanged(),
		);
		const task = record.lifecycle.own("preparing", async () => {
			signal?.throwIfAborted();
			const request = await prepare();
			if (signal?.aborted) {
				request.free();
				signal.throwIfAborted();
			}
			if (this.#stopped) {
				request.free();
				throw new Error("This workspace is closed");
			}
			record.request = request;
			record.lifecycle.phase = "admitting";
			record.lifecycle.outcome = "unknown";
			await this.#submitAcquisition(id);
		}).finally(async () => {
			record.task = undefined;
			if (record.request == null && record.lifecycle.outcome !== "committed") this.#forget(id);
			try {
				await record.cancellation?.idle();
			} finally {
				this.#running.delete(task);
			}
		}).catch((error: unknown) => {
			if (!this.#acquisitions.has(id)) signal?.throwIfAborted();
			throw error;
		});
		record.task = task;
		this.#running.add(task);
		this.#session.acquisitionChanged();
		return task;
	}
	#forget(id: string): void {
		this.#acquisitions.get(id)?.cancellation?.dispose();
		this.#acquisitions.delete(id);
	}
	recoverAcquisition(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const record = this.#acquisitions.get(id);
		if (record == null) return Promise.reject(new Error("This acquisition is no longer held"));
		if (record.task != null) return record.task;
		const task = record.lifecycle.own("acquiring", () => this.#submitAcquisition(id)).finally(() => {
			record.task = undefined;
			this.#running.delete(task);
		});
		record.task = task;
		this.#running.add(task);
		this.#session.acquisitionChanged();
		return task;
	}

	/** An acquisition whose press was cancelled keeps its result until this
	 * owner proves non-admission or completes its recovery. Wait for that
	 * proof, then say the caller may retry its work. A held acquisition that
	 * was not cancelled is left exactly where it stands. */
	async #recoveredIfAborted(acquisition: string): Promise<boolean> {
		const held = this.#acquisitions.get(acquisition);
		if (held == null || !held.signal?.aborted) return false;
		await this.recoverAcquisition(acquisition);
		return true;
	}
	async #submitAcquisition(id: string): Promise<void> {
		const record = this.#acquisitions.get(id)!;
		if (record.lifecycle.outcome === "committed") {
			await this.#session.refresh();
			await record.completed?.();
			this.#forget(id);
			this.#session.acquisitionChanged();
			return;
		}
		const original = record.request;
		if (original == null) throw new Error("This acquisition is no longer held");
		let request: Acquisition = original;
		let outcome;
		for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
			outcome = await submitAcquisition(request);
			if (
				outcome !== "conflict" || !isRepreparable(request) || this.#stopped ||
				attempt + 1 === MAX_CONFLICT_REPREPARATIONS || record.signal?.aborted === true
			) break;
			// Only a proved refusal permits a new revision. Rust re-preparation
			// retains the exact acquired target, source, coordinates and recipe.
			// Failure leaves the original held; uncertainty never enters this path.
			const replacement: Acquisition = await request.reprepare();
			record.request = replacement;
			request.free();
			request = replacement;
			if (record.signal?.aborted) break;
		}
		if (outcome === "committed" && id.startsWith("arrival:")) this.#receivedArrival = id;
		record.lifecycle.outcome = outcome === "committed" ? "committed" : "notAdmitted";
		request.free();
		record.request = undefined;
		if (outcome !== "committed") this.#forget(id);
		this.#session.acquisitionChanged();
		if (id === "workspace-import" && this.#importing == null) this.#importState = null;
		await this.#session.refresh();
		if (outcome === "committed") await record.completed?.();
		this.#forget(id);
		if (outcome === "conflict") {
			record.signal?.throwIfAborted();
			throw new AcquisitionConflict();
		}
	}
	async directory(
		id: string,
		route: string,
		nick: JoinNicknameIntent,
		home: boolean,
		signal?: AbortSignal,
	): Promise<void> {
		await this.#share(
			JSON.stringify(["directory", id, route, nick, home]),
			() =>
				this.#acquire(
					`directory:${id}`,
					() =>
						this.#session.workspace.prepareDirectory(
							id,
							route,
							nick.kind === "exact" ? nick.name : nick.base,
							home,
							nick.kind === "exact",
						),
					JSON.stringify([route, nick, home]),
					undefined,
					signal,
				),
			signal,
		);
	}
	publicRoom(directory: string, name: string, publication: string, opening?: ConversationOpening): Promise<string> {
		return this.#share(
			JSON.stringify(["publicRoom", directory, name, publication]),
			() => this.#publicRoom(directory, name, publication, opening),
			opening?.signal,
		);
	}
	async #publicRoom(
		directory: string,
		name: string,
		publication: string,
		opening?: ConversationOpening,
	): Promise<string> {
		const signal = opening?.signal;
		const acquisition = JSON.stringify(["publicRoom", directory, publication]);
		if (await this.#recoveredIfAborted(acquisition)) {
			return this.#publicRoom(directory, name, publication, opening);
		}
		const id = this.#acquisitions.get(acquisition)?.result ?? crypto.randomUUID();
		const selection = JSON.stringify({ id, directory, name, publication, source: fieldKey() });
		const accepted = this.#session.current;
		const initial = await this.#session.candidate();
		const original = (accepted ?? initial).intent.directories.find((row) => row.id === directory);
		if (original == null) throw new Error("The original directory was removed");
		for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
			signal?.throwIfAborted();
			const snapshot = attempt === 0 ? initial : await this.#session.candidate();
			const current = snapshot.intent.directories.find((row) => row.id === directory);
			if (current == null || current.access !== original.access || current.source !== original.source) {
				throw new Error("The selected directory authority changed. Review it before joining a room.");
			}
			const held = snapshot.intent.conversations.find((row) =>
				row.kind === "room" && row.directory === directory && row.publication === publication
			);
			if (held != null) {
				if (this.#acquisitions.has(acquisition)) await this.recoverAcquisition(acquisition);
				return held.id;
			}
			try {
				await this.#acquire(
					acquisition,
					async () => {
						const request = await this.#session.workspace.preparePublicRoom(snapshot.revision, selection);
						if (request == null) throw new AcquisitionConflict();
						return request;
					},
					JSON.stringify([directory, publication, name]),
					id,
					signal,
					opening == null ? undefined : () => opening.acquired(id),
				);
				return id;
			} catch (error) {
				// Only a proved conflict permits preparation at a newer revision.
				// An uncertain submission remains held by the acquisition owner.
				if (!(error instanceof AcquisitionConflict) || attempt + 1 === MAX_CONFLICT_REPREPARATIONS) {
					throw error;
				}
			}
		}
		throw new Error("Room join exceeded conflict re-preparation attempts.");
	}
	createRoom(directory: string, name: string, policy: RoomPolicy, opening?: ConversationOpening): Promise<string> {
		return this.#share(
			JSON.stringify(["createRoom", directory, name, policy]),
			() => createManagedRoom(this.#session, directory, name, policy, opening),
			opening?.signal,
		);
	}

	async direct(
		directory: string,
		peer: string,
		select: boolean,
		expectedRegistration?: string,
		opening?: ConversationOpening,
	): Promise<string> {
		const id = await this.#share(
			JSON.stringify(["direct", directory, peer, expectedRegistration]),
			() => acquireDirect(this.#session, directory, peer, expectedRegistration, opening),
			opening?.signal,
		);
		if (select) await this.#session.navigation.select(id);
		return id;
	}
	#share<T>(key: string, work: () => Promise<T>, signal?: AbortSignal): Promise<T> {
		const previous = this.#gestures.get(key);
		if (previous != null) {
			if (!previous.signal?.aborted) return previous.task as Promise<T>;
			// A new press waits for the cancelled attempt's cleanup. Only proved
			// non-admission or completed cleanup permits a fresh acquisition.
			return previous.task.then(() => this.#share(key, work, signal), (error: unknown) => {
				if (error instanceof DOMException && error.name === "AbortError") return this.#share(key, work, signal);
				throw error;
			});
		}
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		if (this.#gestures.size >= SESSION_CONTENT.limits.effects) {
			return Promise.reject(new Error("Finish pending actions before starting another one"));
		}
		let start!: () => void;
		const task = new Promise<T>((resolve, reject) => {
			start = () => {
				try {
					resolve(work());
				} catch (error) {
					reject(error);
				}
			};
		}).finally(() => this.#gestures.delete(key));
		this.#gestures.set(key, { task, signal });
		// Install deduplication first, then capture the selected authority on the
		// press. Deferring work to a microtask would capture a later selection.
		start();
		return task;
	}
	run(name: string, args: string[] = []): Promise<unknown> {
		const work = async () => this.#session.completeResult(await this.#session.command(name, args));
		return gestureScope(name, args) == null ? work() : this.#share(JSON.stringify([name, args]), work);
	}
	async clear(): Promise<void> {
		await this.run("clearWorkspace");
	}
	async post(conversation: string, text: string): Promise<void> {
		const command = await this.#session.command("say", [conversation, text]);
		await this.acquireLine(conversation, command);
	}
	async acquireLine(conversation: string, command: ManagedOperation): Promise<CompletedLine> {
		const target = retainedIntentConversation(command.request.originalIntent());
		if (target !== conversation) throw new Error("The line receipt belongs to another conversation");
		const completed = await this.#session.completeResult(command);
		if (!(completed instanceof CompletedLine)) throw new Error("The receipt is not a posted line");
		return completed;
	}

	async replace(
		snapshot: WorkspaceSnapshot,
		releases: Coordinate[] = [],
		imports: { coordinate: Coordinate; uri: string }[] = [],
		source?: string,
	): Promise<void> {
		await this.#acquire("workspace-acquisition", () =>
			this.#session.workspace.prepareAcquisition(
				snapshot.revision,
				JSON.stringify(imports),
				JSON.stringify(releases),
				JSON.stringify(snapshot.intent),
				source == null ? undefined : JSON.stringify({ role: "sessionAccess", key: source }),
			), JSON.stringify([snapshot.intent, releases, imports, source]));
	}
	async operations(
		original: Pick<WorkspaceIntent, "operators" | "operations">,
		replacement: Pick<WorkspaceIntent, "operators" | "operations">,
		imports: { coordinate: Coordinate; uri: string }[],
	): Promise<void> {
		await this.#acquire("operations-acquisition", async () => {
			const result = await this.#session.workspace.prepareOperationsAcquisition(
				JSON.stringify(imports),
				JSON.stringify(original),
				JSON.stringify(replacement),
			);
			if (result.status === "refused") throw new OperationsAcquisitionRefused(result.failures);
			return result;
		}, JSON.stringify([original, replacement, imports]));
	}
	importState(raw: string, presentation = false): Promise<void> {
		// One gesture retains its original request after an uncertain reply.
		const id = "workspace-import";
		if (this.#importState != null) {
			if (this.#importState !== raw) {
				return Promise.reject(
					new Error("Recover the original workspace import before importing another workspace"),
				);
			}
			return this.#importing ?? this.recoverAcquisition(id);
		}
		this.#importState = raw;
		return this.#importing = (async () => {
			const snapshot = await this.#session.candidate();
			await this.#acquire(
				id,
				() =>
					presentation
						? this.#session.workspace.preparePresentationImport(raw)
						: this.#session.workspace.prepareConfigurationImport(snapshot.revision, raw),
			);
		})().finally(() => {
			this.#importing = null;
			if (!this.#acquisitions.has(id)) this.#importState = null;
		});
	}
	acceptInvitation(id: string): Promise<void> {
		return this.#share(JSON.stringify(["acceptInvitation", id]), () => this.#acceptInvitation(id));
	}
	async #acceptInvitation(id: string): Promise<void> {
		const offered = this.#session.current?.intent.invitations.find((row) => row.id === id);
		if (offered?.authority.role === "roomAccess") {
			const snapshot = await this.#session.candidate();
			const invitation = snapshot.intent.invitations.find((row) => row.id === id);
			if (invitation?.authority.role !== "roomAccess") throw new Error("The original invitation changed");
			const room = crypto.randomUUID();
			snapshot.intent.conversations.push({
				kind: "room",
				id: room,
				directory: invitation.directory,
				name: invitation.label,
				access: invitation.authority.key,
				source: invitation.source,
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			snapshot.intent.invitations = snapshot.intent.invitations.filter((row) => row.id !== id);
			snapshot.intent.active = room;
			await this.replace(snapshot);
			return;
		}
		const command = await this.#session.command("acceptInvitation", [id, fieldKey()]);
		await this.#session.completeResult(command);
	}

	async receive(page: ActivityPage): Promise<void> {
		const event = page.event;
		const incoming = event?.route ?? event?.authority;
		if (event == null || incoming == null) return;
		const id = `arrival:${page.cursor}`;
		if (this.#receivedArrival === id) {
			await this.#session.refresh();
			return;
		}
		if (this.#acquisitions.has(id)) return await this.recoverAcquisition(id);
		const snapshot = await this.#session.candidate();
		const conversation = snapshot.intent.conversations.find((row) => row.id === event.target.id);
		if (conversation?.kind !== "direct") throw new Error("The initiating direct conversation is no longer held");
		const notice = event.notice;
		const source = fieldKey();
		const key = fieldKey();
		let destination: Coordinate;
		if (notice?.kind === "line" && event.route != null) {
			destination = { role: "directAccess", key };
			conversation.access = key;
			conversation.source = source;
		} else if (notice?.kind === "handRoom" || notice?.kind === "offerRoom") {
			destination = { role: "roomAccess", key };
			snapshot.intent.invitations.push({
				id,
				directory: conversation.directory,
				label: notice.label ?? "",
				from: conversation.peer,
				authority: { role: "roomAccess", key },
				source,
			});
		} else if (notice?.kind === "handArchive" || notice?.kind === "offerArchive") {
			const kind = notice.scope;
			if (kind !== "room" && kind !== "direct" && kind !== "standing") {
				throw new Error("Invalid received archive scope");
			}
			destination = { role: "archiveAccess", key };
			snapshot.intent.archiveShares = [...(snapshot.intent.archiveShares ?? []), {
				id,
				channel: conversation.id,
				directory: notice.directory ?? "",
				kind,
				conversation: notice.conversation ?? null,
				from: conversation.peer,
				access: key,
				source,
				durable: notice.kind === "offerArchive",
			}];
		} else {
			throw new Error("This incoming authority has no acquisition owner");
		}
		await this.#acquire(
			id,
			() =>
				incoming.prepareAcquisition(
					snapshot.revision,
					JSON.stringify(destination),
					"[]",
					JSON.stringify(snapshot.intent),
					JSON.stringify({ role: "sessionAccess", key: source }),
				),
		);
	}
	roomLink(
		directory: string,
		uri: string,
		name: string,
		selection: { route: string; nick: JoinNicknameIntent; home: boolean },
		opening?: ConversationOpening,
	): Promise<string> {
		return this.#share(
			JSON.stringify(["roomLink", directory, uri, name, selection]),
			() => this.#roomLink(directory, uri, name, selection, opening),
			opening?.signal,
		);
	}
	async #roomLink(
		directory: string,
		uri: string,
		name: string,
		selection: { route: string; nick: JoinNicknameIntent; home: boolean },
		opening?: ConversationOpening,
	): Promise<string> {
		const signal = opening?.signal;
		const acquisition = `room-link:${directory}`;
		const intent = JSON.stringify([uri, name, selection]);
		if (await this.#recoveredIfAborted(acquisition)) {
			return this.#roomLink(directory, uri, name, selection, opening);
		}
		const held = this.#acquisitions.get(acquisition);
		if (held != null) {
			if (held.intent !== intent) {
				throw new Error("Recover the original room link before opening a different one");
			}
			await this.recoverAcquisition(acquisition);
			return held.result!;
		}
		const snapshot = await this.#session.candidate();
		const id = crypto.randomUUID();
		const access = fieldKey();
		const source = fieldKey();
		const imports = [{ coordinate: { role: "roomAccess", key: access }, uri }];
		const nick = selection.nick.kind === "exact" ? selection.nick.name : selection.nick.base;
		const nickAllocation = selection.nick.kind === "exact" ? "exact" : "automatic";
		const row = snapshot.intent.directories.find((row) => row.id === directory);
		if (row == null) {
			const directoryAccess = fieldKey();
			imports.push({
				coordinate: { role: "directoryAccess", key: directoryAccess },
				uri: applicationModule().directoryCapability(selection.route),
			});
			if (selection.home) { for (const directory of snapshot.intent.directories) directory.home = false; }
			snapshot.intent.directories.push({
				id: directory,
				access: directoryAccess,
				source,
				home: selection.home,
				nick,
				nickAllocation,
				standing: null,
			});
		} else if (row.nick !== nick || row.nickAllocation !== nickAllocation) {
			row.nick = nick;
			row.nickAllocation = nickAllocation;
			delete row.assignedNick;
		}
		// One gesture stages nickname intent, optional directory custody and room
		// authority together. Supervisors cannot replace its inbox between two
		// separate page mutations, and a refused fetch changes no directory.
		snapshot.intent.conversations.push({
			kind: "room",
			id,
			directory,
			name: name || managedText.sharedRoom,
			source,
			access,
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		await this.#acquire(
			acquisition,
			() =>
				this.#session.workspace.prepareAcquisition(
					snapshot.revision,
					JSON.stringify(imports),
					"[]",
					JSON.stringify(snapshot.intent),
					JSON.stringify({ role: "sessionAccess", key: source }),
				),
			intent,
			id,
			signal,
			opening == null ? undefined : () => opening.acquired(id),
		);
		return id;
	}
	stop(): void {
		this.#stopped = true;
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled([...this.#running, ...[...this.#gestures.values()].map((row) => row.task)]);
		for (const record of this.#acquisitions.values()) {
			record.cancellation?.dispose();
			record.request?.free();
		}
		this.#acquisitions.clear();
	}
}
