// Direct conversations realized inside one durable session directory.

import { Ref, retainSecondaryFailure, type Session } from "@glowcap/runtime";
import type { Message } from "../lib/room/client.ts";
import { DirectMessage, directMessageReceiverBehavior } from "../lib/direct_message.ts";
import { type Attachment, attachmentCapabilities } from "../lib/attachment.ts";
import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import type { LiveDirectory } from "./live.ts";
import { directoryDirects } from "./topology.ts";
import { directReceivedLineBehavior, DurableDirectLine } from "./direct_line.ts";
import { parseRoomsSturdyref, roomsAddress } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import type { ArchiveCoordinates } from "../lib/archive/protocol.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { DirectConversationRouteAttempt } from "./direct_route_attempt.ts";
import { type ConversationEventObserver, emitTypingEvent } from "./conversation_events.ts";
import { DIRECT_NOT_ACCEPTED, RoomError } from "../lib/errors.ts";

function directNotAccepted(): RoomError {
	return new RoomError(DIRECT_NOT_ACCEPTED, "that exact direct conversation is no longer accepted");
}

function refuseUnacceptedMessage(
	session: Session,
	reply: Ref | null,
	attachments: Attachment[],
	callbacks: DirectRealizationCallbacks,
): never {
	const capabilities = attachmentCapabilities(attachments);
	if (reply != null) capabilities.add(reply);
	for (const capability of capabilities) {
		void callbacks.cleanup(
			Promise.resolve().then(() => session.release(capability)),
			"an unaccepted direct message capability would not release",
		);
	}
	throw directNotAccepted();
}

export function directEmitter(
	archive: DurableRoomsArchive,
	receivers: ReadonlySet<ConversationEventObserver>,
	keepHistory: () => boolean,
): DirectRealizationCallbacks["emit"] {
	return (held, conversationId, generation, message, editable, files) =>
		emitDirectMessage(
			archive,
			receivers,
			keepHistory(),
			held,
			conversationId,
			generation,
			message,
			editable,
			files,
		);
}

export function directTypingEmitter(
	receivers: ReadonlySet<ConversationEventObserver>,
): DirectRealizationCallbacks["typing"] {
	return (_held, conversationId, peer, on) => emitTypingEvent(receivers, conversationId, peer, on);
}

export interface DirectRealizationCallbacks {
	setIssue(subject: string, error: unknown | null): boolean;
	subjects(): Iterable<string>;
	receive(
		held: LiveDirectory,
		conversationId: string,
		peer: string,
		text: string,
		attachments: Attachment[],
		session: Session,
	): Ref;
	emit(
		held: LiveDirectory,
		conversationId: string,
		generation: string,
		message: Message,
		editable: boolean,
		files?: RuntimeAttachment[],
	): void;
	onInvitation(
		directory: string,
		label: string,
		link: string,
		from: string,
		locator: string,
		nick: string,
	): Promise<void> | void;
	handRoom(held: LiveDirectory, owner: Session, label: string, room: Ref, from: string): Promise<void> | void;
	acceptDirect?(
		held: LiveDirectory,
		peer: string,
		peerRegistrationId: string,
	): Promise<string>;
	typing?(held: LiveDirectory, conversationId: string, peer: string, on: boolean): void;
	archiveShare?(
		held: LiveDirectory,
		owner: Session,
		directory: unknown,
		kind: unknown,
		conversation: unknown,
		archive: Ref,
		from: string,
		fromRegistrationId: string,
	): Promise<void> | void;
	archiveOffer?(
		held: LiveDirectory,
		directory: unknown,
		kind: unknown,
		conversation: unknown,
		sturdyref: string,
		from: string,
		fromRegistrationId: string,
	): Promise<void> | void;
	closeConversation?(held: LiveDirectory, conversationId: string): void;
	routeChanged?(): void;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
}

export function receiveDirect(
	held: LiveDirectory,
	conversationId: string,
	peer: string,
	text: string,
	attachments: Attachment[],
	session: Session,
	emit: DirectRealizationCallbacks["emit"],
): Ref {
	const direct = held.directs.get(conversationId);
	if (direct == null) throw new Error("that direct conversation is not connected in this Rooms session");
	const lineId = direct.nextLineId();
	const message = { from: peer, text, system: false, lineId, change: "said" as const, attachments };
	const line = session.spawn(
		directReceivedLineBehavior(peer, lineId, attachments, (message) => {
			const files = direct.files.retainIncoming(message, session);
			emit(held, conversationId, direct.generation, message, false, files);
		}),
	);
	const files = direct.files.retainIncoming(message, session);
	emit(held, conversationId, direct.generation, message, true, files);
	return line;
}

function emitDirectMessage(
	archive: DurableRoomsArchive,
	receivers: ReadonlySet<
		(
			conversationId: string,
			message: Message,
			editable: boolean,
			files: RuntimeAttachment[],
			history: ArchiveCoordinates | null,
		) => void
	>,
	keep: boolean,
	held: LiveDirectory,
	conversationId: string,
	generation: string,
	message: Message,
	editable: boolean,
	files: RuntimeAttachment[] = [],
): void {
	const history = archive.recordMessage({
		keep,
		generation,
		kind: "direct",
		directory: held.id,
		conversation: conversationId,
		nick: held.nick,
		message,
		files,
	});
	for (const receive of receivers) receive(conversationId, message, editable, files, history);
}

export async function sendDirectFiles(
	held: LiveDirectory,
	conversationId: string,
	caption: string,
	files: import("../lib/attachment.ts").AttachmentSource[],
	emit: DirectRealizationCallbacks["emit"],
): Promise<void> {
	const direct = held.directs.get(conversationId);
	if (direct == null) throw new Error("that direct conversation is not connected in this Rooms session");
	const sent = await direct.sendFiles(held.nick, caption, files);
	emit(held, conversationId, direct.generation, sent.message, sent.editable, sent.files);
}

export function notifyInvitations(
	invitations: ReadonlySet<DirectRealizationCallbacks["onInvitation"]>,
	directory: string,
	label: string,
	link: string,
	from: string,
	locator: string,
	nick: string,
): Promise<void> {
	return Promise.all([...invitations].map((received) => received(directory, label, link, from, locator, nick)))
		.then(() => {});
}

export async function reconcileDirects(
	held: LiveDirectory,
	conversations: readonly WorkspaceConversation[],
	callbacks: DirectRealizationCallbacks,
): Promise<void> {
	const wanted = new Map(
		directoryDirects(held.id, conversations).map((conversation) => [conversation.id, conversation]),
	);
	const prefix = `direct:${held.id}:`;
	for (const subject of callbacks.subjects()) {
		if (
			subject.startsWith(prefix) &&
			(wanted.get(subject.slice(prefix.length))?.closed ?? true)
		) callbacks.setIssue(subject, null);
	}
	held.directIntents.clear();
	held.directConversationByRegistration.clear();
	for (const entry of wanted.values()) {
		if (entry.closed) continue;
		held.directIntents.set(entry.id, {
			peer: entry.peer,
			peerRegistrationId: entry.peerRegistrationId,
			topology: JSON.stringify({
				peer: entry.peer,
				peerRegistrationId: entry.peerRegistrationId,
				closed: entry.closed,
			}),
		});
		held.directConversationByRegistration.set(
			entry.peerRegistrationId,
			held.directConversationByRegistration.has(entry.peerRegistrationId) ? null : entry.id,
		);
	}
	const requestPrefix = `direct-request:${held.id}:`;
	for (const subject of callbacks.subjects()) {
		if (
			subject.startsWith(requestPrefix) &&
			!held.directConversationByRegistration.has(subject.slice(requestPrefix.length))
		) callbacks.setIssue(subject, null);
	}
	for (const [id, opening] of held.directRouteAttempts) {
		if (held.directIntents.get(id)?.topology === opening.topology) continue;
		opening.conversationChanged();
	}
	for (const [id, live] of held.directs) {
		const intent = held.directIntents.get(id);
		if (intent?.topology === live.topology) continue;
		held.directs.delete(id);
		callbacks.closeConversation?.(held, id);
		await callbacks.cleanup(live.close(), "a replaced direct conversation would not close");
	}
}

/** Realize one intended direct conversation on demand. One opening owns the
 * directory introduction; a reciprocal route that arrives first wins and the
 * redundant opened line is retired before this settles. */
export function ensureDirectRoute(
	held: LiveDirectory,
	conversationId: string,
	callbacks: DirectRealizationCallbacks,
	requestReciprocal = true,
): Promise<void> {
	const live = held.directs.get(conversationId);
	if (live?.line.live) return Promise.resolve();
	const pending = held.directRouteAttempts.get(conversationId);
	if (pending != null) return pending.promise;
	const intent = held.directIntents.get(conversationId);
	if (intent == null) {
		return Promise.reject(new Error("that direct conversation is not intended in this Rooms session"));
	}
	const subject = `direct:${held.id}:${conversationId}`;
	const opening = new DirectConversationRouteAttempt(intent.topology);
	held.directRouteAttempts.set(conversationId, opening);
	void opening.promise.then(
		() => {
			if (held.directRouteAttempts.get(conversationId) === opening) {
				held.directRouteAttempts.delete(conversationId);
			}
			callbacks.setIssue(subject, null);
		},
		(error) => {
			if (held.directRouteAttempts.get(conversationId) === opening) {
				held.directRouteAttempts.delete(conversationId);
			}
			callbacks.setIssue(subject, error);
		},
	);
	const attempt = DirectMessage.open(held.directory, intent.peer, {
		message: (text, attachments, session, reply) => {
			if (reply != null) {
				void callbacks.cleanup(
					Promise.resolve().then(() => session.release(reply)),
					"a redundant direct reply route would not release",
				);
			}
			return callbacks.receive(held, conversationId, intent.peer, text, attachments, session);
		},
		ready: (session, reply) => {
			void callbacks.cleanup(
				Promise.resolve().then(() => session.release(reply)),
				"a redundant direct-ready route would not release",
			);
		},
		typing: (on) => callbacks.typing?.(held, conversationId, intent.peer, on),
	}, intent.peerRegistrationId);
	opening.trackOpening(
		attempt.then(async (line) => {
			if (opening.settled) {
				await callbacks.cleanup(line.close(), "a late direct opening would not close");
				return;
			}
			const currentIntent = held.directIntents.get(conversationId);
			if (currentIntent?.topology !== intent.topology) {
				await callbacks.cleanup(line.close(), "an obsolete direct opening would not close");
				opening.conversationChanged();
				return;
			}
			const arrived = held.directs.get(conversationId);
			if (arrived?.line.live) {
				await callbacks.cleanup(line.close(), "a redundant reciprocal direct route would not close");
				opening.established();
				return;
			}
			if (arrived != null) await callbacks.cleanup(arrived.close(), "a stale direct route would not close");
			const realized = new DurableDirectLine(intent.topology, line);
			held.directs.set(conversationId, realized);
			callbacks.routeChanged?.();
			opening.established();
		}, async (error) => {
			if (!requestReciprocal) {
				opening.failed(error);
				return;
			}
			try {
				await held.directory.requestDirect(intent.peer, intent.peerRegistrationId);
			} catch (requestFailure) {
				opening.failed(retainSecondaryFailure(error, requestFailure));
				return;
			}
			if (held.directs.get(conversationId)?.line.live === true) {
				opening.established();
				return;
			}
			callbacks.setIssue(subject, error);
			opening.reciprocalRequested(error);
		}).catch((error) => opening.failed(error)),
	);
	return opening.promise;
}

/** Answer a reciprocal request only for an already-intended registration.
 * Opening the reverse carrier never creates a conversation, and failure does
 * not request another reversal back from the peer. */
export async function establishRequestedDirectRoute(
	held: LiveDirectory,
	peerRegistrationId: string,
	callbacks: DirectRealizationCallbacks,
): Promise<void> {
	const conversationId = conversationForPeer(held, peerRegistrationId);
	if (conversationId == null) return;
	await ensureDirectRoute(held, conversationId, callbacks, false);
	const direct = held.directs.get(conversationId);
	if (direct == null) throw new Error("the requested direct conversation did not establish a route");
	await direct.line.establishReplyRoute();
}

/** Refuse every route attempt whose intended topology is gone, and wait until
 * its callers have observed that terminal result. */
export async function cancelDirectRouteAttempts(held: LiveDirectory): Promise<void> {
	const pending = [...held.directRouteAttempts.values()];
	held.directRouteAttempts.clear();
	await Promise.allSettled(pending.map((opening) => opening.directoryClosed()));
}

function conversationForPeer(held: LiveDirectory, peerRegistrationId: string): string | null {
	return held.directConversationByRegistration.get(peerRegistrationId) ?? null;
}

function adoptDirectRoute(
	held: LiveDirectory,
	peer: string,
	peerRegistrationId: string,
	session: Session,
	reply: Ref,
	callbacks: DirectRealizationCallbacks,
): string {
	const conversation = conversationForPeer(held, peerRegistrationId);
	if (conversation == null) {
		void callbacks.cleanup(
			Promise.resolve().then(() => session.release(reply)),
			"an unaccepted reciprocal direct route would not release",
		);
		throw directNotAccepted();
	}
	const existing = held.directs.get(conversation);
	if (existing?.line.usesRoute(session, reply)) {
		void callbacks.cleanup(
			Promise.resolve().then(() => session.release(reply)),
			"a repeated direct reply occurrence would not release",
		);
	} else if (existing?.line.live) {
		void callbacks.cleanup(
			Promise.resolve().then(() => session.release(reply)),
			"a redundant reciprocal direct route would not release",
		);
	} else {
		if (existing != null) void callbacks.cleanup(existing.close(), "a stale direct conversation would not close");
		const intent = held.directIntents.get(conversation);
		if (intent == null) throw new Error("that direct conversation is not intended in this Rooms session");
		held.directs.set(
			conversation,
			new DurableDirectLine(intent.topology, DirectMessage.adopt(session, reply, peer, peerRegistrationId)),
		);
		callbacks.routeChanged?.();
	}
	held.directRouteAttempts.get(conversation)?.established();
	callbacks.setIssue(`direct:${held.id}:${conversation}`, null);
	return conversation;
}

export function directInbox(
	held: LiveDirectory,
	peer: string,
	peerRegistrationId: string,
	callbacks: DirectRealizationCallbacks,
) {
	return directMessageReceiverBehavior({
		ready: (session, reply) => {
			adoptDirectRoute(held, peer, peerRegistrationId, session, reply, callbacks);
		},
		offerRoom: (label, link) => {
			if (link === "") throw new Error("a room-link invitation needs a nonempty sturdyref");
			const locator = parseRoomsSturdyref(link).locator;
			return callbacks.onInvitation(
				roomsPeerAuthority(locator),
				label,
				link,
				peer,
				roomsAddress(locator),
				held.nick,
			);
		},
		handRoom: (label, room, owner) => callbacks.handRoom(held, owner, label, room, peer),
		typing: (on) => {
			const conversation = conversationForPeer(held, peerRegistrationId);
			if (conversation == null) throw directNotAccepted();
			callbacks.typing?.(held, conversation, peer, on);
		},
		handArchive: (directory, kind, conversation, archive, owner) => {
			if (callbacks.archiveShare == null) {
				const refusal = new Error("archive sharing is unavailable on this direct line");
				try {
					owner.release(archive);
				} catch (cleanup) {
					throw retainSecondaryFailure(refusal, cleanup);
				}
				throw refusal;
			}
			return callbacks.archiveShare(
				held,
				owner,
				directory,
				kind,
				conversation,
				archive,
				peer,
				peerRegistrationId,
			);
		},
		offerArchive: (directory, kind, conversation, sturdyref) => {
			if (callbacks.archiveOffer == null) {
				throw new Error("durable archive offers are unavailable on this direct line");
			}
			return callbacks.archiveOffer(held, directory, kind, conversation, sturdyref, peer, peerRegistrationId);
		},
		message: (text, attachments, session, reply) => {
			const existing = conversationForPeer(held, peerRegistrationId);
			if (existing == null) refuseUnacceptedMessage(session, reply, attachments, callbacks);
			if (reply != null) adoptDirectRoute(held, peer, peerRegistrationId, session, reply, callbacks);
			return callbacks.receive(held, existing, peer, text, attachments, session);
		},
	});
}
