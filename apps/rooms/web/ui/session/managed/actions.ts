import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
// Page gestures acquire exact receipt occurrences. Rust executes all effects.
import type {
	RoomsManagedAcquisition,
	RoomsManagedDirectoryAcquisition,
	RoomsManagedOperationsAcquisition,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { ManagedRoomsSession } from "./session.ts";
import type { ManagedOperation } from "./operation.ts";
import { WorkspaceConflict } from "./operation.ts";
import { type ActivityPage, type Coordinate, fieldKey, type WorkspaceIntent, type WorkspaceSnapshot } from "./model.ts";
import type { JoinNicknameIntent } from "../../controller/session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import { applicationModule } from "../../application.ts";
import { AcquisitionConflict, submitAcquisition } from "./acquisition.ts";
import type { OpsCap } from "../../types.ts";

export class OperationsAcquisitionRefused extends Error {
	constructor(readonly failures: readonly { capability: OpsCap; reason: string; advice: string | null }[]) {
		super(managedText.operationsAcquisitionRefused);
	}
}

type Acquisition = RoomsManagedAcquisition | RoomsManagedDirectoryAcquisition | RoomsManagedOperationsAcquisition;
export class ManagedActions {
	readonly #session: ManagedRoomsSession;
	readonly #acquisitions = new Map<string, Acquisition>();
	readonly #preparing = new Set<string>();
	readonly #running = new Set<Promise<unknown>>();
	readonly #submitting = new Map<string, Promise<void>>();
	#stopped = false;
	// The activity reader presents one cursor at a time. Keep its completed
	// arrival through projection retry, even after custody acquisition is settled.
	#receivedArrival: string | null = null;
	#importState: string | null = null;
	#importing: Promise<void> | null = null;
	constructor(session: ManagedRoomsSession) {
		this.#session = session;
	}
	get pending(): readonly string[] {
		return [...this.#acquisitions.keys()];
	}
	get recoverable(): readonly string[] {
		return this.pending.filter((id) => !this.#submitting.has(id));
	}
	#acquire(id: string, prepare: () => Promise<Acquisition>): Promise<void> {
		const task = this.#prepareAcquisition(id, prepare).finally(() => this.#running.delete(task));
		this.#running.add(task);
		return task;
	}
	async #prepareAcquisition(id: string, prepare: () => Promise<Acquisition>): Promise<void> {
		if (this.#stopped) throw new Error("This workspace is closed");
		if (this.#acquisitions.has(id) || this.#preparing.has(id)) {
			throw new Error("Recover the original acquisition before preparing another one");
		}
		if (this.#acquisitions.size + this.#preparing.size >= 32) {
			throw new Error("Recover pending acquisitions before preparing another one");
		}
		this.#preparing.add(id);
		let request: Acquisition;
		try {
			request = await prepare();
			if (this.#stopped) {
				request.free();
				throw new Error("This workspace is closed");
			}
		} finally {
			this.#preparing.delete(id);
		}
		this.#acquisitions.set(id, request);
		await this.recoverAcquisition(id);
	}
	recoverAcquisition(id: string): Promise<void> {
		if (this.#stopped) return Promise.reject(new Error("This workspace is closed"));
		const existing = this.#submitting.get(id);
		if (existing != null) return existing;
		const task = this.#submitAcquisition(id).finally(() => {
			this.#submitting.delete(id);
			this.#session.acquisitionChanged();
		});
		this.#submitting.set(id, task);
		this.#session.acquisitionChanged();
		return task;
	}
	async #submitAcquisition(id: string): Promise<void> {
		const original = this.#acquisitions.get(id);
		if (original == null) throw new Error("This acquisition is no longer held");
		let request: Acquisition = original;
		let outcome;
		for (let attempt = 0;; attempt++) {
			outcome = await submitAcquisition(request);
			if (outcome !== "conflict" || !("reprepare" in request) || attempt === 3 || this.#stopped) break;
			// Only a proved refusal permits a new revision. Rust re-preparation
			// retains the exact acquired target, source, coordinates and recipe.
			// Failure leaves the original held; uncertainty never enters this path.
			const replacement: Acquisition = await request.reprepare();
			this.#acquisitions.set(id, replacement);
			request.free();
			request = replacement;
		}
		if (outcome === "committed" && id.startsWith("arrival:")) this.#receivedArrival = id;
		request.free();
		this.#acquisitions.delete(id);
		this.#session.acquisitionChanged();
		if (id === "workspace-import" && this.#importing == null) this.#importState = null;
		await this.#session.refresh();
		if (outcome === "conflict") throw new AcquisitionConflict();
	}
	async directory(id: string, route: string, nick: JoinNicknameIntent, home: boolean): Promise<void> {
		await this.#acquire(`directory:${id}`, () =>
			this.#session.workspace.prepareDirectory(
				id,
				route,
				nick.kind === "exact" ? nick.name : nick.base,
				home,
				nick.kind === "exact",
			));
	}
	async publicRoom(directory: string, name: string, publication: string): Promise<string> {
		const id = crypto.randomUUID();
		const selection = JSON.stringify({ id, directory, name, publication, source: fieldKey() });
		const initial = await this.#session.candidate();
		const original = initial.intent.directories.find((row) => row.id === directory);
		if (original == null) throw new Error("The original directory was removed");
		for (let attempt = 0;; attempt++) {
			const snapshot = attempt === 0 ? initial : await this.#session.candidate();
			const current = snapshot.intent.directories.find((row) => row.id === directory);
			if (current == null || current.access !== original.access || current.source !== original.source) {
				throw new Error("The selected directory authority changed. Review it before joining a room.");
			}
			const held = snapshot.intent.conversations.find((row) =>
				row.kind === "room" && row.directory === directory && row.publication === publication
			);
			if (held != null) return held.id;
			try {
				await this.#acquire(`room:${id}`, async () => {
					const request = await this.#session.workspace.preparePublicRoom(snapshot.revision, selection);
					if (request == null) throw new AcquisitionConflict();
					return request;
				});
				return id;
			} catch (error) {
				// Only a proved conflict permits preparation at a newer revision.
				// An uncertain submission remains held by the acquisition owner.
				if (!(error instanceof AcquisitionConflict) || attempt === 3) throw error;
			}
		}
	}
	async createRoom(directory: string, name: string, policy: RoomPolicy): Promise<string> {
		const original = (await this.#session.refresh()).intent.directories.find((row) => row.id === directory);
		if (original == null) throw new Error("The original directory was removed");
		const access = original.access;
		const source = original.source;
		const operation = crypto.randomUUID();
		const args = [
			directory,
			name,
			policy.visibility,
			policy.entry,
			policy.speaking,
			`~${fieldKey()}`,
		];
		for (let attempt = 0;; attempt++) {
			let command: ManagedOperation;
			try {
				command = await this.#session.command("openManagedRoom", args, operation, (snapshot) => {
					const current = snapshot.intent.directories.find((row) => row.id === directory);
					if (current == null || current.access !== access || current.source !== source) {
						throw new Error("The selected directory authority changed. Review it before creating a room.");
					}
				});
			} catch (error) {
				// Conflict proves that no receipt or upstream effect was installed.
				// Every preparation rechecks the same directory/source; uncertain
				// admissions stay at command's existing original receipt owner.
				if (!(error instanceof WorkspaceConflict) || attempt === 3) throw error;
				continue;
			}
			await this.#session.completeResult(command);
			return command.id;
		}
	}

	async direct(directory: string, peer: string, select: boolean, expectedRegistration?: string): Promise<string> {
		const initial = await this.#session.refresh();
		const original = initial.intent.directories.find((row) => row.id === directory);
		if (original?.name == null || original.inbox == null) {
			throw new Error("The initiating registration was retired");
		}
		const reader = await this.#session.workspace.directoryReader(directory);
		let registration: string;
		try {
			registration = await reader.memberRegistration(peer);
		} finally {
			reader.free();
		}
		if (expectedRegistration != null && registration !== expectedRegistration) {
			throw new Error(
				"That name now has a different registration. Start a separate conversation from the directory.",
			);
		}
		const checkOrigin = (snapshot: WorkspaceSnapshot) => {
			const origin = snapshot.intent.directories.find((row) => row.id === directory);
			if (origin?.name == null || origin.inbox == null) {
				throw new Error("The initiating registration was retired");
			}
			if (
				origin.access !== original.access || origin.source !== original.source ||
				origin.name !== original.name || origin.inbox !== original.inbox
			) {
				throw new Error("The initiating registration changed while selecting the peer");
			}
			return origin;
		};
		const current = await this.#session.refresh();
		const origin = checkOrigin(current);
		const existing = current.intent.conversations.find((row) =>
			row.kind === "direct" && row.directory === directory && row.peer === peer && !row.closed &&
			row.introduction?.access === origin.access && row.introduction.name === origin.name &&
			row.introduction.callback === origin.inbox && row.introduction.registration === registration
		);
		if (existing != null) {
			if (select) await this.#session.navigation.select(existing.id);
			return existing.id;
		}
		const opening = crypto.randomUUID();
		// Install the scalar readiness waiter before asking for an introduction.
		// Only the original directory and exact registration can wake it.
		const readiness = this.#session.waitNotice((event) =>
			event.target.kind === "directory" && event.target.id === directory &&
			event.notice.kind === "introducible" && event.notice.registration === registration &&
			event.notice.opening === opening
		);
		try {
			const introduce = () =>
				this.#session.command("startDirect", [directory, peer, registration, opening], undefined, checkOrigin);
			let command = await introduce();
			let result = await command.result() as { status: "ready" | "pending"; inbox?: string };
			if (result.status === "pending") {
				this.#session.finish(command);
				await readiness.ready;
				command = await introduce();
				result = await command.result() as typeof result;
			}
			if (result.status !== "ready" || result.inbox == null) {
				throw new Error("The original direct introduction has no ready route");
			}
			await this.#session.completeResult(command);
			const adopted = (await this.#session.refresh()).intent.conversations.find((row) =>
				row.kind === "direct" && row.directory === directory && !row.closed &&
				row.introduction?.registration === registration && row.introduction.opening === opening
			);
			if (adopted == null) throw new Error("The original direct introduction is no longer held");
			if (select) await this.#session.navigation.select(adopted.id);
			return adopted.id;
		} finally {
			readiness.cancel();
		}
	}
	async run(name: string, args: string[] = []): Promise<unknown> {
		const command = await this.#session.command(name, args);
		return await this.#session.completeResult(command);
	}
	async clear(): Promise<void> {
		await this.run("clearWorkspace");
	}
	async post(conversation: string, text: string): Promise<void> {
		const command = await this.#session.command("say", [conversation, text]);
		await this.acquireLine(conversation, command);
	}
	async acquireLine(conversation: string, command: ManagedOperation): Promise<void> {
		const original = command.request.originalIntent();
		const target = Array.isArray(original) ? original[3][0] : original.conversation;
		if (target !== conversation) throw new Error("The line receipt belongs to another conversation");
		await this.#session.completeResult(command);
	}

	async replace(
		snapshot: WorkspaceSnapshot,
		releases: Coordinate[] = [],
		imports: { coordinate: Coordinate; uri: string }[] = [],
		source?: string,
	): Promise<void> {
		await this.#acquire(crypto.randomUUID(), () =>
			this.#session.workspace.prepareAcquisition(
				snapshot.revision,
				JSON.stringify(imports),
				JSON.stringify(releases),
				JSON.stringify(snapshot.intent),
				source == null ? undefined : JSON.stringify({ role: "sessionAccess", key: source }),
			));
	}
	async operations(
		original: Pick<WorkspaceIntent, "operators" | "operations">,
		replacement: Pick<WorkspaceIntent, "operators" | "operations">,
		imports: { coordinate: Coordinate; uri: string }[],
	): Promise<void> {
		await this.#acquire(crypto.randomUUID(), async () => {
			const result = await this.#session.workspace.prepareOperationsAcquisition(
				JSON.stringify(imports),
				JSON.stringify(original),
				JSON.stringify(replacement),
			);
			if (result.status === "refused") throw new OperationsAcquisitionRefused(result.failures);
			return result;
		});
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
	async acceptInvitation(id: string): Promise<void> {
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
		const source = fieldKey();
		const key = fieldKey();
		let destination: Coordinate;
		if (event.notice.kind === "line" && event.route != null) {
			destination = { role: "directAccess", key };
			conversation.access = key;
			conversation.source = source;
		} else if (event.notice.kind === "handRoom" || event.notice.kind === "offerRoom") {
			destination = { role: "roomAccess", key };
			snapshot.intent.invitations.push({
				id,
				directory: conversation.directory,
				label: String(event.notice.label ?? ""),
				from: conversation.peer,
				authority: { role: "roomAccess", key },
				source,
			});
		} else if (event.notice.kind === "handArchive" || event.notice.kind === "offerArchive") {
			const kind = event.notice.scope;
			if (kind !== "room" && kind !== "direct" && kind !== "standing") {
				throw new Error("Invalid received archive scope");
			}
			destination = { role: "archiveAccess", key };
			snapshot.intent.archiveShares = [...(snapshot.intent.archiveShares ?? []), {
				id,
				channel: conversation.id,
				directory: String(event.notice.directory),
				kind,
				conversation: event.notice.conversation == null ? null : String(event.notice.conversation),
				from: conversation.peer,
				access: key,
				source,
				durable: event.notice.kind === "offerArchive",
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
	async roomLink(
		directory: string,
		uri: string,
		name: string,
		selection: { route: string; nick: JoinNicknameIntent; home: boolean },
	): Promise<string> {
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
		snapshot.intent.active = id;
		await this.replace(snapshot, [], imports, source);
		return id;
	}
	stop(): void {
		this.#stopped = true;
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled([...this.#running, ...this.#submitting.values()]);
		for (const request of this.#acquisitions.values()) request.free();
		this.#acquisitions.clear();
	}
}
