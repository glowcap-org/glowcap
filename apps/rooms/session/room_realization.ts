// One durable session's room realization for one directory.

import { retainCleanupFailures } from "@pancake/runtime";
import { enterOrOpen } from "../lib/enter_room.ts";
import { type Message, type PostedLine, Room } from "../lib/room_client.ts";
import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import { MAX_SCROLLBACK } from "../lib/limits.ts";
import { roomsConversationTopology, roomsIrcIntentTopology } from "./topology.ts";
import { RoomFileCustody, type RuntimeAttachment } from "./room_files.ts";
import { applyRoomView, freshRoomView } from "./room_view.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { roomsSturdyrefForSession } from "../lib/locator.ts";

export class RoomRealization {
	readonly rooms = new Map<string, LiveRoom>();

	async close(
		release: (live: LiveRoom) => void,
		cleanup: (work: Promise<unknown>, label: string) => Promise<void>,
	): Promise<void> {
		for (const live of [...this.rooms.values()].reverse()) {
			release(live);
			await cleanup(live.room.leave(), "a room would not leave");
		}
		this.rooms.clear();
	}

	async reconcile(
		held: LiveDirectory,
		conversations: readonly WorkspaceConversation[],
		setIssue: (subject: string, error: unknown | null) => boolean,
		cleanup: (work: Promise<unknown>, label: string) => Promise<void>,
		release: (live: LiveRoom) => void,
		drain: (conversation: Extract<WorkspaceConversation, { kind: "room" }>, room: Room) => void,
	): Promise<void> {
		const wanted = new Map(
			conversations.filter((conversation): conversation is Extract<WorkspaceConversation, { kind: "room" }> =>
				conversation.kind === "room" && conversation.directory === held.id
			).map((conversation) => [conversation.id, conversation]),
		);
		for (const subject of [...this.rooms.keys()]) {
			if (!wanted.has(subject)) setIssue(`room:${held.id}:${subject}`, null);
		}
		for (const [id, live] of this.rooms) {
			const saved = wanted.get(id);
			const ircIntent = saved == null ? null : roomsIrcIntentTopology(saved);
			if (
				saved != null && live.topology === roomsConversationTopology(saved) &&
				!(ircIntent === "automatic" && live.ircIntent !== "automatic")
			) {
				await this.#reconcileIrc(held, live, saved, setIssue);
				continue;
			}
			this.rooms.delete(id);
			release(live);
			await cleanup(live.room.leave(), "a replaced room would not leave");
		}
		for (const conversation of wanted.values()) {
			if (this.rooms.has(conversation.id)) continue;
			const subject = `room:${held.id}:${conversation.id}`;
			try {
				if (conversation.held && conversation.link == null) {
					throw new Error(`${conversation.name} needs its one-session room reference again`);
				}
				const reference = conversation.link != null
					? await held.directory.session.enliven(
						roomsSturdyrefForSession(conversation.link, held.directory.session),
					)
					: conversation.publicationId != null
					? await held.directory.enterPublication(conversation.publicationId)
					: await enterOrOpen(held.directory, conversation.name);
				const room = await Room.subscribe(held.directory.session, reference, held.nick);
				try {
					if (conversation.steward != null) await room.takeSteward(conversation.steward);
				} catch (error) {
					throw await retainCleanupFailures(error, [() => room.leave()]);
				}
				const live = {
					topology: roomsConversationTopology(conversation),
					ircIntent: "automatic",
					room,
					generation: crypto.randomUUID(),
					pendingLines: [],
					postedLines: new Map(),
					files: new RoomFileCustody(room),
					view: freshRoomView(),
					standing: null,
				};
				this.rooms.set(conversation.id, live);
				setIssue(subject, null);
				drain(conversation, room);
				await this.#reconcileIrc(held, live, conversation, setIssue);
			} catch (error) {
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

	async #reconcileIrc(
		held: LiveDirectory,
		live: LiveRoom,
		conversation: Extract<WorkspaceConversation, { kind: "room" }>,
		setIssue: (subject: string, error: unknown | null) => boolean,
	): Promise<void> {
		const intended = roomsIrcIntentTopology(conversation);
		if (live.ircIntent === intended) return;
		const subject = `room-irc:${held.id}:${conversation.id}`;
		setIssue(subject, null);
		try {
			if (conversation.irc === null) await live.room.disconnectIrc();
			else if (conversation.irc != null) {
				await live.room.ircIdentity(
					conversation.irc.nick,
					conversation.irc.account,
					conversation.irc.password,
				);
			}
			live.ircIntent = intended;
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
		callbacks: RoomDrainCallbacks,
	): Promise<void> {
		await this.reconcile(
			held,
			conversations,
			setIssue,
			cleanup,
			release,
			(conversation, room) => void this.drain(held, conversation, room, callbacks),
		);
	}

	async drain(
		held: LiveDirectory,
		conversation: Extract<WorkspaceConversation, { kind: "room" }>,
		room: Room,
		callbacks: RoomDrainCallbacks,
	): Promise<void> {
		try {
			for await (const message of room.messages) {
				const live = this.rooms.get(conversation.id);
				let editable = false;
				if (
					live?.room === room && message.from === held.nick && message.change === "said" &&
					message.lineId != null
				) {
					const authority = live.pendingLines.shift();
					const line = await authority;
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
						message.presence?.kind === "irc-seat" && message.presence.name === held.nick &&
						message.presence.state === "failed"
					) live.ircIntent = "failed";
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
					this.rooms.get(conversation.id)?.generation ?? null,
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
	scheduleRetry(): void;
	scheduleRoomViewNotify(): void;
	setIssue(subject: string, error: unknown): void;
}
