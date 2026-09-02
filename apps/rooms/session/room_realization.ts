// One durable session's room realization for one directory.

import { PublicationNotFound, type Ref, retainCleanupFailures } from "@glowcap/runtime";
import { enterOrOpenResult } from "../lib/enter_room.ts";
import { NOT_STEWARD, roomErrorOf } from "../lib/errors.ts";
import { roomAuthorityToken } from "../lib/room/authority.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import { type Message, type PostedLine, Room } from "../lib/room/client.ts";
import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import { MAX_SCROLLBACK } from "../lib/limits.ts";
import {
	directoryRooms,
	type RoomConversation,
	roomsBridgeIntentTopology,
	roomsConversationTopology,
} from "./topology.ts";
import { RoomFileCustody, type RuntimeAttachment } from "./room_files.ts";
import { applyRoomView, freshRoomView } from "./room_view.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import type { RoomAuthorityAcquisition, RoomAuthorityRetirement, RoomReconnectResult } from "./state_sync.ts";
import { ReconciliationBlocked } from "./reconnect.ts";
import { RoomManagerMismatch } from "../lib/room/manager.ts";

export class RoomRealization {
	readonly rooms = new Map<string, LiveRoom>();
	readonly #expectedEvents = new Map<string, string>();

	/** Install the newest desired room topology before queued reconciliation
	 * reaches it. Subscription callbacks remain live across unrelated revisions,
	 * but stop the instant a newer checkpoint removes or replaces their room. */
	expectEvents(directoryId: string, conversations: readonly WorkspaceConversation[]): void {
		this.#expectedEvents.clear();
		for (const conversation of conversations) {
			if (conversation.kind === "room" && conversation.directory === directoryId) {
				this.#expectedEvents.set(conversation.id, roomsConversationTopology(conversation));
			}
		}
	}

	acceptsEvent(conversationId: string, room: Room): boolean {
		const live = this.rooms.get(conversationId);
		return live?.room === room && this.#expectedEvents.get(conversationId) === live.topology;
	}

	async close(
		release: (live: LiveRoom) => void,
		cleanup: (work: Promise<unknown>, label: string) => Promise<void>,
	): Promise<void> {
		const rooms = [...this.rooms.values()].reverse();
		// Fence callbacks before the first asynchronous leave. A directory being
		// closed is no longer an event source even while its carrier unwinds.
		this.rooms.clear();
		this.#expectedEvents.clear();
		for (const live of rooms) {
			await cleanup(Promise.resolve().then(() => release(live)), "room resources would not release");
			await cleanup(live.room.leave(), "a room would not leave");
		}
	}

	async reconcile(
		held: LiveDirectory,
		conversations: readonly WorkspaceConversation[],
		setIssue: (subject: string, error: unknown | null) => boolean,
		cleanup: (work: Promise<unknown>, label: string) => Promise<void>,
		release: (live: LiveRoom) => void,
		reconcileAuthority: (retired: RoomAuthorityRetirement) => Promise<void>,
		reconcileAcquisition: (acquired: RoomAuthorityAcquisition) => Promise<void>,
		reconcileReconnect: (result: RoomReconnectResult) => Promise<void>,
		current: () => boolean,
		notifyView: () => void,
		typing: (conversationId: string, peer: string, on: boolean) => void,
		bridgeSecrets: (directoryId: string, scope: string) => Record<string, string> | null,
		drain: (conversation: RoomConversation, room: Room) => void,
	): Promise<void> {
		this.expectEvents(held.id, conversations);
		const wanted = new Map(
			directoryRooms(held.id, conversations).map((conversation) => [conversation.id, conversation]),
		);
		for (const subject of [...this.rooms.keys()]) {
			if (!wanted.has(subject)) setIssue(`room:${held.id}:${subject}`, null);
		}
		for (const [id, live] of this.rooms) {
			if (!current()) return;
			const saved = wanted.get(id);
			const bridgeIntent = saved == null ? null : roomsBridgeIntentTopology(saved);
			if (
				saved != null && live.topology === roomsConversationTopology(saved) &&
				saved.reconnect !== "requested" &&
				!(bridgeIntent === "automatic" && live.bridgeIntent !== "automatic")
			) {
				await this.#reconcileManager(live, saved, reconcileAuthority);
				await this.#reconcileSteward(live, saved, reconcileAuthority);
				if (!current()) return;
				await this.#reconcileBridge(held, live, saved, setIssue, bridgeSecrets);
				continue;
			}
			this.rooms.delete(id);
			release(live);
			await cleanup(live.room.leave(), "a replaced room would not leave");
			if (!current()) return;
		}
		for (const conversation of wanted.values()) {
			if (!current()) return;
			if (this.rooms.has(conversation.id)) continue;
			const subject = `room:${held.id}:${conversation.id}`;
			try {
				if (conversation.reconnect === "manual") {
					throw new ReconciliationBlocked(
						`${conversation.name} needs an explicit rejoin or a current room link`,
					);
				}
				if (conversation.held && conversation.link == null) {
					throw new ReconciliationBlocked(`${conversation.name} needs a new room link or handoff`);
				}
				let realized = conversation;
				let acquired: RoomAuthorityAcquisition | null = null;
				let reference: Ref | undefined;
				if (conversation.link != null) {
					try {
						reference = await held.directory.session.enliven(conversation.link);
					} catch (error) {
						if (!(error instanceof PublicationNotFound)) throw error;
						await reconcileAuthority({
							conversationId: conversation.id,
							kind: "room",
							token: roomAuthorityToken(conversation.link),
							claimable: false,
						});
						throw new ReconciliationBlocked(`${conversation.name}'s saved room link was retired`);
					}
				}
				if (!current()) return;
				if (reference == null) {
					if (conversation.publicationId != null) {
						reference = await held.directory.enterPublication(conversation.publicationId);
					} else {
						const reached = await enterOrOpenResult(held.directory, conversation.name);
						reference = reached.ref;
						if (reached.managerLink != null && reached.roomLink != null) {
							acquired = {
								type: "room-authority-acquired",
								conversationId: conversation.id,
								roomLink: reached.roomLink,
								managerLink: reached.managerLink,
							};
							realized = { ...realized, link: reached.roomLink, manager: reached.managerLink };
						}
					}
				}
				let subscribed: Room | null = null;
				const room = await Room.subscribe(
					held.directory.session,
					reference,
					held.nick,
					{
						onTyping: (peer, on) => {
							if (subscribed != null && this.acceptsEvent(conversation.id, subscribed)) {
								typing(conversation.id, peer, on);
							}
						},
						onAuthorityChanged: (_changedRoom, change) => {
							void reconcileAuthority({ conversationId: conversation.id, ...change }).catch(() => {});
						},
						onPolicyChanged: (changedRoom, policy) => {
							const currentRoom = this.rooms.get(conversation.id);
							if (currentRoom?.room !== changedRoom) return;
							currentRoom.view.policy = policy;
							notifyView();
						},
					},
				);
				subscribed = room;
				if (!current()) {
					await cleanup(room.leave(), "a superseded room would not leave");
					return;
				}
				try {
					if (realized.manager != null) {
						try {
							await room.takeManager(realized.manager);
						} catch (error) {
							if (!(error instanceof PublicationNotFound) && !(error instanceof RoomManagerMismatch)) {
								throw error;
							}
							await reconcileAuthority({
								conversationId: conversation.id,
								kind: "manager",
								token: roomAuthorityToken(realized.manager),
								claimable: false,
							});
							realized = { ...realized, manager: undefined };
						}
					}
					if (conversation.steward != null) {
						try {
							await room.takeSteward(conversation.steward);
						} catch (error) {
							if (roomErrorOf(error)?.code !== NOT_STEWARD) throw error;
							await reconcileAuthority({
								conversationId: conversation.id,
								kind: "steward",
								token: roomAuthorityToken(conversation.steward),
								claimable: false,
							});
							realized = { ...realized, steward: undefined };
						}
					}
				} catch (error) {
					throw await retainCleanupFailures(error, [() => room.leave()]);
				}
				if (!current()) {
					await cleanup(room.leave(), "a superseded room would not leave");
					return;
				}
				const policy = await room.policy();
				const live = {
					topology: roomsConversationTopology(realized),
					source: conversation.publicationId == null
						? "local" as const
						: held.view.room(conversation.publicationId)?.kind ?? "unknown" as const,
					bridgeIntent: "automatic",
					room,
					generation: crypto.randomUUID(),
					pendingLines: [],
					postedLines: new Map(),
					files: new RoomFileCustody(room),
					view: freshRoomView(room.membershipKind, policy),
					standing: null,
				};
				this.rooms.set(conversation.id, live);
				if (acquired != null) await reconcileAcquisition(acquired);
				setIssue(subject, null);
				drain(conversation, room);
				await this.#reconcileBridge(held, live, conversation, setIssue, bridgeSecrets);
				if (conversation.reconnect === "requested") {
					await reconcileReconnect({
						type: "room-reconnect",
						conversationId: conversation.id,
						connected: true,
					}).catch(() => {});
				}
			} catch (error) {
				if (conversation.reconnect === "requested") {
					await reconcileReconnect({
						type: "room-reconnect",
						conversationId: conversation.id,
						connected: false,
					}).catch(() => {});
				}
				if (setIssue(subject, error)) {
					console.error(
						`rooms session: could not restore ${conversation.name}: ${
							error instanceof Error ? error.message : error
						}`,
					);
				}
			}
		}
	}

	async #reconcileManager(
		live: LiveRoom,
		conversation: RoomConversation,
		reconcileAuthority: (retired: RoomAuthorityRetirement) => Promise<void>,
	): Promise<void> {
		if (conversation.manager == null) {
			if (live.room.managerLink != null) live.room.dropManager();
			return;
		}
		if (live.room.managerLink === conversation.manager) return;
		try {
			await live.room.takeManager(conversation.manager);
		} catch (error) {
			if (!(error instanceof PublicationNotFound) && !(error instanceof RoomManagerMismatch)) throw error;
			await reconcileAuthority({
				conversationId: conversation.id,
				kind: "manager",
				token: roomAuthorityToken(conversation.manager),
				claimable: false,
			});
		}
	}

	async #reconcileSteward(
		live: LiveRoom,
		conversation: RoomConversation,
		reconcileAuthority: (retired: RoomAuthorityRetirement) => Promise<void>,
	): Promise<void> {
		if (conversation.steward == null) {
			if (live.room.stewardLink != null) live.room.dropSteward();
			return;
		}
		if (live.room.stewardLink === conversation.steward) return;
		try {
			await live.room.takeSteward(conversation.steward);
		} catch (error) {
			if (roomErrorOf(error)?.code !== NOT_STEWARD) throw error;
			await reconcileAuthority({
				conversationId: conversation.id,
				kind: "steward",
				token: roomAuthorityToken(conversation.steward),
				claimable: live.room.canClaimSteward,
			});
		}
	}

	async #reconcileBridge(
		held: LiveDirectory,
		live: LiveRoom,
		conversation: RoomConversation,
		setIssue: (subject: string, error: unknown | null) => boolean,
		bridgeSecrets: (directoryId: string, scope: string) => Record<string, string> | null,
	): Promise<void> {
		const intended = roomsBridgeIntentTopology(conversation);
		if (live.bridgeIntent === intended) return;
		const subject = `room-bridge:${held.id}:${conversation.id}`;
		setIssue(subject, null);
		try {
			// What the reader answered, answered again. The secrets are not in the
			// checkpoint, so they come from the runtime's own custody; a reconnect
			// that no longer holds one asks rather than guessing, because a wrong
			// guess here is a failed login somebody has to go and understand.
			if (conversation.bridgeIntent != null) {
				// Only a submission that needed a secret has to find one. The rest
				// replay from the checkpoint alone, which is most of them.
				const secrets = conversation.bridgeIntent.secretsGiven
					? bridgeSecrets(held.id, conversation.bridgeIntent.scope)
					: {};
				if (secrets === null) throw new Error("answer this bridge again to restore its saved identity");
				await live.room.submitBridgeForm(conversation.bridgeIntent.action, {
					...conversation.bridgeIntent.answers,
					...secrets,
				});
			}
			live.bridgeIntent = intended;
			setIssue(subject, null);
		} catch (error) {
			if (setIssue(subject, error)) {
				console.error(
					`rooms session: could not apply the IRC identity for ${conversation.name}: ${
						error instanceof Error ? error.message : error
					}`,
				);
			}
		}
	}

	async reconcileAndDrain(
		held: LiveDirectory,
		conversations: readonly WorkspaceConversation[],
		setIssue: (subject: string, error: unknown | null) => boolean,
		cleanup: (work: Promise<unknown>, label: string) => Promise<void>,
		release: (live: LiveRoom) => void,
		reconcileAuthority: (retired: RoomAuthorityRetirement) => Promise<void>,
		reconcileAcquisition: (acquired: RoomAuthorityAcquisition) => Promise<void>,
		reconcileReconnect: (result: RoomReconnectResult) => Promise<void>,
		current: () => boolean,
		notifyView: () => void,
		bridgeSecrets: (directoryId: string, scope: string) => Record<string, string> | null,
		callbacks: RoomDrainCallbacks,
	): Promise<void> {
		await this.reconcile(
			held,
			conversations,
			setIssue,
			cleanup,
			release,
			reconcileAuthority,
			reconcileAcquisition,
			reconcileReconnect,
			current,
			notifyView,
			callbacks.typing,
			bridgeSecrets,
			(conversation, room) => void this.drain(held, conversation, room, callbacks),
		);
	}

	async drain(
		held: LiveDirectory,
		conversation: RoomConversation,
		room: Room,
		callbacks: RoomDrainCallbacks,
	): Promise<void> {
		const started = this.rooms.get(conversation.id);
		if (started?.room !== room) return;
		const generation = started.generation;
		const releaseStaleMessage = (message: Message, line: PostedLine | null = null) => {
			if (line != null) settleCapabilityCleanup("stale posted-line release failed", () => line.release());
			for (const attachment of message.attachments) {
				settleCapabilityCleanup("stale room attachment release failed", () => room.release(attachment));
			}
		};
		try {
			for await (const message of room.messages) {
				const live = this.rooms.get(conversation.id);
				if (live?.room !== room || live.generation !== generation) {
					releaseStaleMessage(message);
					return;
				}
				let editable = false;
				if (
					live?.room === room && message.from === held.nick && message.change === "said" &&
					message.lineId != null
				) {
					const authority = live.pendingLines.shift();
					const line = await authority;
					if (this.rooms.get(conversation.id) !== live) {
						releaseStaleMessage(message, line);
						return;
					}
					if (line != null) {
						live.postedLines.set(message.lineId, line);
						editable = true;
						while (live.postedLines.size > MAX_SCROLLBACK) {
							const oldest = live.postedLines.entries().next().value as [number, PostedLine] | undefined;
							if (oldest == null) break;
							live.postedLines.delete(oldest[0]);
							oldest[1].release();
						}
					}
				} else if (live?.postedLines.has(message.lineId ?? -1)) editable = true;
				if (live?.room === room) {
					if (
						message.presence?.kind === "seat" && message.presence.name === held.nick &&
						message.presence.state === "failed"
					) live.bridgeIntent = "failed";
					live.files.apply(message);
					applyRoomView(live.view, message);
					if (message.presence != null || message.facts != null) callbacks.scheduleRoomViewNotify();
				}
				const files = live?.room === room ? live.files.project(message) : [];
				callbacks.message(
					conversation.id,
					message,
					editable,
					files,
					generation,
				);
			}
			if (this.rooms.get(conversation.id)?.room === room) throw new Error("the room message stream ended");
		} catch (error) {
			const live = this.rooms.get(conversation.id);
			if (live?.room !== room) return;
			this.rooms.delete(conversation.id);
			callbacks.release(live);
			callbacks.setIssue(`room:${held.id}:${conversation.id}`, error);
			callbacks.scheduleRetry();
		}
	}
}

export interface RoomDrainCallbacks {
	release(live: LiveRoom): void;
	message(
		conversationId: string,
		message: Message,
		editable: boolean,
		files: RuntimeAttachment[],
		generation: string | null,
	): void;
	typing(conversationId: string, peer: string, on: boolean): void;
	scheduleRetry(): void;
	scheduleRoomViewNotify(): void;
	setIssue(subject: string, error: unknown): void;
}
