// Page gestures acquire exact receipt occurrences. Rust executes all effects.
import { invariant } from "../../../../lib/invariant.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { conversationById } from "./conversation_lookup.ts";
import type { Committed } from "./committed.ts";
import type { Door, ManagedRoomsSession } from "./session.ts";
import type { ManagedOperation } from "./operation.ts";
import type { ConversationOpening } from "./openings.ts";
import { acquireDirect } from "./direct.ts";
import { createManagedRoom } from "./create_room.ts";
import { type ActivityPage, type Coordinate, fieldKey, type WorkspaceIntent, type WorkspaceSnapshot } from "./model.ts";
import type { JoinNicknameIntent } from "../../controller/session.ts";
import type { RoomPolicy } from "../../room_policy.ts";
import { AcquisitionConflict, MAX_CONFLICT_REPREPARATIONS, OperationsAcquisitionRefused } from "./acquisition.ts";
import { retainedIntentConversation } from "./admission.ts";
import { CompletedLine } from "./completed_line.ts";
import { stageRoomLink } from "./room_link.ts";
import { stageArrival } from "./arrival.ts";
import { gestureScope } from "./gestures.ts";
import { SESSION_CONTENT } from "../../../../lib/session_content_data.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import { type AcquisitionSession, HeldAcquisitions } from "./held_acquisitions.ts";
import type { LinkPort, Stamp } from "./link_port.ts";

/** What actions use of the session: what the held acquisitions and the
 * presses it opens use, and the navigation the actions change. */
export type ActionSession = AcquisitionSession & Door & Pick<ManagedRoomsSession, "navigation">;

/** One press of a gesture whose later presses share its task while it runs. */
interface Gesture<T> {
	task: Promise<T>;
	signal?: AbortSignal;
}

/** The id of the room held by exactly `uri`, read through `custody`. */
async function roomEntered(
	snapshot: WorkspaceSnapshot | null,
	custody: (coordinate: string) => Promise<string | null>,
	uri: string,
): Promise<string | null> {
	for (const row of snapshot?.intent.conversations ?? []) {
		if (row.kind !== "room" || row.access == null) continue;
		if (await custody(JSON.stringify({ role: "roomAccess", key: row.access })) === uri) return row.id;
	}
	return null;
}

/** `roomEnteredBy` for a press that has sent its change: no read waits. The
 * answer is `undefined` when the session could not be read, which is not the
 * same as a room that was not entered. */
function roomEnteredAfter(after: Committed, uri: string): Promise<{ id: string | null } | undefined> {
	return after.readOr<{ id: string | null } | undefined>(undefined, async (reads) => ({
		id: await roomEntered(
			reads.current,
			(coordinate) => reads.requestNow((workspace) => workspace.custodyRecipe(coordinate)),
			uri,
		),
	}));
}

export class ManagedActions {
	readonly #session: ActionSession;
	readonly #held: HeldAcquisitions;
	/** Gestures that answer the id of what they opened, and gestures whose
	 * answer is only that they ended. One bound covers both. */
	readonly #opening = new Map<string, Gesture<string>>();
	readonly #acting = new Map<string, Gesture<unknown>>();
	/** Room-link gestures, which answer null when the session could not be
	 * read to say which room holds the link. */
	readonly #linking = new Map<string, Gesture<string | null>>();
	/** The room each room-link acquisition's completion found, or null when
	 * the session could not be read. */
	readonly #entered = new Map<string, string | null>();
	// The activity reader presents one cursor at a time. Keep its completed
	// arrival through projection retry, even after custody acquisition is settled.
	#receivedArrival: string | null = null;
	#importState: string | null = null;
	#importing: Promise<void> | null = null;
	constructor(session: ActionSession, link: LinkPort) {
		this.#session = session;
		this.#held = new HeldAcquisitions(session, link, (id, committed) => {
			if (committed && id.startsWith("arrival:")) this.#receivedArrival = id;
			if (id === "workspace-import" && this.#importing == null) this.#importState = null;
		});
	}
	get diagnostics() {
		return this.#held.diagnostics;
	}
	get resources() {
		return { ...this.#held.resources, gestures: this.#opening.size + this.#acting.size + this.#linking.size };
	}
	get pending(): readonly string[] {
		return this.#held.pending;
	}
	get recoverable(): readonly string[] {
		return this.#held.recoverable;
	}
	release(id: string): Promise<void> {
		return this.#held.release(id);
	}
	get cancelledConversations(): readonly string[] {
		return this.#held.cancelledConversations;
	}
	relink(report: (source: string, error: unknown) => void): void {
		this.#held.relink(report);
	}
	recoverAcquisition(id: string): Promise<void> {
		return this.#held.recover(id);
	}
	async directory(
		id: string,
		route: string,
		nick: JoinNicknameIntent,
		home: boolean,
		signal?: AbortSignal,
	): Promise<void> {
		await this.#share(
			this.#acting,
			JSON.stringify(["directory", id, route, nick, home]),
			() =>
				this.#held.acquire(
					managedText.joiningDirectory,
					`directory:${id}`,
					(workspace) =>
						workspace.prepareDirectory(
							id,
							route,
							nick.kind === "exact" ? nick.name : nick.base,
							home,
							nick.kind === "exact",
						),
					{ intent: JSON.stringify([route, nick, home]), signal },
				),
			signal,
		);
	}
	publicRoom(directory: string, name: string, publication: string, opening?: ConversationOpening): Promise<string> {
		return this.#share(
			this.#opening,
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
		if (await this.#held.recoveredIfAborted(acquisition)) {
			return this.#publicRoom(directory, name, publication, opening);
		}
		const id = this.#held.held(acquisition)?.result ?? crypto.randomUUID();
		const selection = JSON.stringify({ id, directory, name, publication, source: fieldKey() });
		const accepted = this.#session.current;
		const initial = await this.#session.candidateBeforeSending();
		const original = (accepted ?? initial).intent.directories.find((row) => row.id === directory);
		if (original == null) throw new LocalRefusal("directory-gone");
		for (let attempt = 0; attempt < MAX_CONFLICT_REPREPARATIONS; attempt++) {
			signal?.throwIfAborted();
			const snapshot = attempt === 0 ? initial : await this.#session.candidateBeforeSending();
			const current = snapshot.intent.directories.find((row) => row.id === directory);
			if (current == null || current.access !== original.access || current.source !== original.source) {
				throw new LocalRefusal("directory-changed");
			}
			const held = snapshot.intent.conversations.find((row) =>
				row.kind === "room" && row.directory === directory && row.publication === publication
			);
			if (held != null) {
				if (this.#held.held(acquisition) != null) await this.recoverAcquisition(acquisition);
				return held.id;
			}
			try {
				await this.#held.acquire(
					managedText.joiningListedRoom,
					acquisition,
					async (workspace) => {
						const request = await workspace.preparePublicRoom(snapshot.revision, selection);
						if (request == null) throw new AcquisitionConflict();
						return request;
					},
					{
						intent: JSON.stringify([directory, publication, name]),
						result: id,
						signal,
						completed: opening == null ? undefined : () => opening.acquired(id),
					},
				);
				return id;
			} catch (error) {
				// Only a proved conflict permits preparation at a newer revision.
				// An uncertain submission remains held by the acquisition owner.
				if (!(error instanceof AcquisitionConflict)) {
					throw error;
				}
			}
		}
		throw new LocalRefusal("conflict");
	}
	createRoom(directory: string, name: string, policy: RoomPolicy, opening?: ConversationOpening): Promise<string> {
		return this.#share(
			this.#opening,
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
	): Promise<string | null> {
		const id = await this.#share(
			this.#opening,
			JSON.stringify(["direct", directory, peer, expectedRegistration]),
			() => acquireDirect(this.#session, directory, peer, expectedRegistration, opening),
			opening?.signal,
		);
		if (select && id != null) await this.#session.navigation.selectAfterCommit(id);
		return id;
	}
	#share<T>(
		gestures: Map<string, Gesture<T>>,
		key: string,
		work: () => Promise<T>,
		signal?: AbortSignal,
	): Promise<T> {
		const previous = gestures.get(key);
		if (previous != null) {
			if (!previous.signal?.aborted) return previous.task;
			// A new press waits for the cancelled attempt's cleanup. Only proved
			// non-admission or completed cleanup permits a fresh acquisition.
			return previous.task.then(() => this.#share(gestures, key, work, signal), (error: unknown) => {
				if (error instanceof DOMException && error.name === "AbortError") {
					return this.#share(gestures, key, work, signal);
				}
				throw error;
			});
		}
		if (this.#held.stopped) return Promise.reject(new LocalRefusal("session-closed"));
		if (this.#opening.size + this.#acting.size + this.#linking.size >= SESSION_CONTENT.limits.effects) {
			return Promise.reject(new LocalRefusal("busy"));
		}
		const started = Promise.withResolvers<T>();
		const task = started.promise.finally(() => gestures.delete(key));
		gestures.set(key, { task, signal });
		// Install deduplication first, then capture the selected authority on the
		// press. Deferring work to a microtask would capture a later selection.
		try {
			started.resolve(work());
		} catch (error) {
			started.reject(error);
		}
		return task;
	}
	/** Send `name` and acquire its result, finishing over the next link when a
	 * loss ends the press after its commit. */
	run(name: string, args: string[] = [], validate?: (snapshot: WorkspaceSnapshot) => void): Promise<unknown> {
		const operation = crypto.randomUUID();
		const work = () =>
			this.#session.press(
				operation,
				({ command }) => command(name, args, operation, validate),
				(command, after) => after.complete(command),
			);
		return gestureScope(name, args) == null
			? work()
			: this.#share(this.#acting, JSON.stringify([name, args]), work);
	}
	async clear(): Promise<void> {
		await this.run("clearWorkspace");
	}
	async post(conversation: string, text: string): Promise<void> {
		const operation = crypto.randomUUID();
		await this.#session.press(
			operation,
			({ command }) => command("say", [conversation, text], operation),
			async (command, after) => {
				await this.acquireLine(conversation, command, after);
			},
		);
	}
	async acquireLine(
		conversation: string,
		command: ManagedOperation,
		after: Committed,
	): Promise<CompletedLine> {
		const target = retainedIntentConversation(command.request.originalIntent());
		invariant(target === conversation, "the line receipt belongs to another conversation");
		const completed = await after.complete(command);
		invariant(completed instanceof CompletedLine, "the receipt is not a posted line");
		return completed;
	}

	async replace(
		snapshot: WorkspaceSnapshot,
		releases: Coordinate[] = [],
		imports: { coordinate: Coordinate; uri: string }[] = [],
		source?: string,
	): Promise<void> {
		await this.#held.acquire(
			managedText.changingSession,
			"workspace-acquisition",
			(workspace) =>
				workspace.prepareAcquisition(
					snapshot.revision,
					JSON.stringify(imports),
					JSON.stringify(releases),
					JSON.stringify(snapshot.intent),
					source == null ? undefined : JSON.stringify({ role: "sessionAccess", key: source }),
				),
			{ intent: JSON.stringify([snapshot.intent, releases, imports, source]) },
		);
	}
	async operations(
		original: Pick<WorkspaceIntent, "operators" | "operations">,
		replacement: Pick<WorkspaceIntent, "operators" | "operations">,
		imports: { coordinate: Coordinate; uri: string }[],
	): Promise<void> {
		await this.#held.acquire(managedText.operationsInventory, "operations-acquisition", async (workspace) => {
			const result = await workspace.prepareOperationsAcquisition(
				JSON.stringify(imports),
				JSON.stringify(original),
				JSON.stringify(replacement),
			);
			if (result.status === "refused") throw new OperationsAcquisitionRefused(result.failures);
			return result;
		}, { intent: JSON.stringify([original, replacement, imports]) });
	}
	importState(raw: string, presentation = false): Promise<void> {
		// One gesture retains its original request after an uncertain reply.
		const id = "workspace-import";
		if (this.#importState != null) {
			if (this.#importState !== raw) {
				return Promise.reject(
					new LocalRefusal("import-in-progress"),
				);
			}
			return this.#importing ?? this.recoverAcquisition(id);
		}
		this.#importState = raw;
		return this.#importing = (async () => {
			const snapshot = await this.#session.candidateBeforeSending();
			await this.#held.acquire(
				managedText.importingSession,
				id,
				(workspace) =>
					presentation
						? workspace.preparePresentationImport(raw)
						: workspace.prepareConfigurationImport(snapshot.revision, raw),
			);
		})().finally(() => {
			this.#importing = null;
			if (this.#held.held(id) == null) this.#importState = null;
		});
	}
	async acceptInvitation(id: string): Promise<void> {
		await this.#share(this.#acting, JSON.stringify(["acceptInvitation", id]), () => this.#acceptInvitation(id));
	}
	async #acceptInvitation(id: string): Promise<void> {
		const offered = this.#session.current?.intent.invitations.find((row) => row.id === id);
		if (offered?.authority.role === "roomAccess") {
			const snapshot = await this.#session.candidateBeforeSending();
			const invitation = snapshot.intent.invitations.find((row) => row.id === id);
			if (invitation?.authority.role !== "roomAccess") {
				throw new LocalRefusal("invitation-changed");
			}
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
		const operation = crypto.randomUUID();
		await this.#session.press(
			operation,
			({ command }) => command("acceptInvitation", [id, fieldKey()], operation),
			(command, after) => after.complete(command),
		);
	}

	/** Take the arrival `page` holds into the conversation it names. `over` is
	 * the link `page` was read over: its handles travel that link's
	 * connection, so they are prepared only while it is current. */
	async receive(page: ActivityPage, over: Stamp): Promise<void> {
		const event = page.event;
		const incoming = event?.route ?? event?.authority;
		if (event == null || incoming == null) return;
		const id = `arrival:${page.cursor}`;
		if (this.#receivedArrival === id) {
			await this.#session.committed.readOr<unknown>(null, (reads) => reads.readNow());
			return;
		}
		if (this.#held.held(id) != null) return await this.recoverAcquisition(id);
		const snapshot = await this.#session.candidateBeforeSending();
		const conversation = conversationById(snapshot, event.target.id);
		if (conversation?.kind !== "direct") throw new LocalRefusal("conversation-gone");
		const { destination, source } = stageArrival(snapshot, conversation, event, id);
		await this.#held.acquire(
			managedText.receivingDirect,
			id,
			() =>
				incoming.prepareAcquisition(
					snapshot.revision,
					JSON.stringify(destination),
					"[]",
					JSON.stringify(snapshot.intent),
					JSON.stringify({ role: "sessionAccess", key: source }),
				),
			{ over },
		);
	}
	roomLink(
		directory: string,
		uri: string,
		name: string,
		selection: { route: string; nick: JoinNicknameIntent; home: boolean },
		opening?: ConversationOpening,
	): Promise<string | null> {
		return this.#share(
			this.#linking,
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
	): Promise<string | null> {
		const signal = opening?.signal;
		const acquisition = `room-link:${directory}`;
		const intent = JSON.stringify([uri, name, selection]);
		if (await this.#held.recoveredIfAborted(acquisition)) {
			return this.#roomLink(directory, uri, name, selection, opening);
		}
		const held = this.#held.held(acquisition);
		if (held != null) {
			if (held.intent !== intent) {
				throw new LocalRefusal("access-change-retained");
			}
			// A room link acquisition is made with its staged row's id as its
			// result, so a held one always names the row it opens.
			invariant(held.result != null, "this room link acquisition names no room");
			await this.recoverAcquisition(acquisition);
			return this.#enteredBy(acquisition);
		}
		const snapshot = await this.#session.candidateBeforeSending();
		const { id, source, imports } = stageRoomLink(snapshot, directory, uri, name, selection);
		// A link to a room this session already stands in becomes that room's
		// way in, and the staged row goes, so the row holding the link after the
		// commit is the one to show. A pre-existing room is not this opening's
		// to leave if it is abandoned.
		await this.#held.acquire(
			managedText.openingRoomLink,
			acquisition,
			(workspace) =>
				workspace.prepareAcquisition(
					snapshot.revision,
					JSON.stringify(imports),
					"[]",
					JSON.stringify(snapshot.intent),
					JSON.stringify({ role: "sessionAccess", key: source }),
				),
			{
				intent,
				result: id,
				signal,
				// Over the next link when a loss ends it, so the commit's answer is
				// the room that holds `uri`, never a refusal of the read.
				completed: async (after) => {
					const read = await roomEnteredAfter(after, uri);
					// An unread session names no room: the id staged here may not
					// be a row if the session already stood in that room.
					this.#entered.set(acquisition, read == null ? null : read.id ?? id);
					if (read != null && (read.id ?? id) === id) await opening?.acquired(id);
				},
			},
		);
		return this.#enteredBy(acquisition);
	}
	#enteredBy(acquisition: string): string | null {
		const entered = this.#entered.get(acquisition) ?? null;
		this.#entered.delete(acquisition);
		return entered;
	}
	/** The id of the room this session entered by exactly `uri`, or null, for a
	 * press that has sent nothing: the read waits for the link. */
	async roomEnteredBy(uri: string): Promise<string | null> {
		return await roomEntered(
			this.#session.current,
			(coordinate) => this.#session.request((workspace) => workspace.custodyRecipe(coordinate)),
			uri,
		);
	}
	stop(): void {
		this.#held.stop();
	}
	async close(): Promise<void> {
		this.stop();
		await Promise.allSettled(
			[...this.#opening.values(), ...this.#acting.values(), ...this.#linking.values()].map((row) => row.task),
		);
		await this.#held.close();
	}
}
