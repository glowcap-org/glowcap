import type { ArchiveCoordinates } from "../../../lib/archive/protocol.ts";
import { PresenceNarration } from "./presence_narration.ts";
import type { Presence } from "../../../lib/room/presence.ts";
import type { RoomFacts } from "../../../lib/room/message.ts";
import type { FileDescription } from "./attached_files.ts";
export interface PresentedLine<F extends FileDescription = FileDescription> {
	conversationId: string;
	operation?: string;
	from: string;
	text: string;
	at: number;
	lineId: number | null;
	change: "said" | "edited" | "refiled" | "withdrawn" | null;
	editable: boolean;
	history: ArchiveCoordinates | null;
	system: boolean;
	presence?: Presence;
	facts?: RoomFacts;
	previewUrls: string[];
	attachments: F[];
}
// Projection of live attached-session lines into the presentation store.

import * as store from "../store.ts";
import { sameArchiveCoordinates } from "../../../lib/archive/coordinates.ts";
import { lineNotShowable } from "../text.ts";
import { maybeNotify } from "../notify.ts";
import { isStateOnlyRoomEvent } from "../room_event.ts";
import { applyTyping } from "../typing.ts";
import { fetchesOnArrival } from "../media.ts";
import {
	type AttachmentView,
	type ChatItem,
	type Conv,
	type DirId,
	type Item,
	silencedFrom,
	type SysAudience,
} from "../types.ts";
import { type AttachedSessionFiles, EARLIER_CONNECTION_BYTES_UNAVAILABLE } from "./attached_files.ts";
import type { RoomsPageContext } from "../page.ts";

/** What one accepted line event calls for, classified once. The kind carries
 * its custody: `refiled`, `replaced`, and `arrived` adopt the event's
 * occurrences into the log. Every other kind releases them, and `withdrawn`
 * and `refiled` also release the occurrences the row they name held. A new
 * kind is added here together with its case in the disposal switch, so its
 * custody decision is written beside the others and nowhere else. */
type Disposition =
	| { readonly kind: "edited"; readonly named: ChatItem | undefined }
	| { readonly kind: "withdrawn"; readonly named: ChatItem | undefined }
	| { readonly kind: "refiled"; readonly named: ChatItem | undefined }
	| { readonly kind: "system"; readonly audience: SysAudience }
	| { readonly kind: "merged"; readonly named: ChatItem; readonly correlated: Item | undefined }
	| { readonly kind: "replaced"; readonly named: ChatItem; readonly correlated: Item | undefined }
	| { readonly kind: "arrived" };

/** Own the synchronous handoff from one accepted session event to either the
 * visible log or file-capability release. Snapshot topology remains in the
 * parent projection. This owner only resolves its stable conversation key. */
export class AttachedLineProjection<F extends FileDescription = FileDescription> {
	readonly #conversationKey: (conversationId: string) => string | null;
	readonly #files: AttachedSessionFiles<F> | null;
	readonly #page: RoomsPageContext;
	readonly #presence = new PresenceNarration();

	constructor(
		conversationKey: (conversationId: string) => string | null,
		files: AttachedSessionFiles<F> | null,
		page: RoomsPageContext,
	) {
		this.#conversationKey = conversationKey;
		this.#files = files;
		this.#page = page;
	}

	apply(event: PresentedLine<F>): void {
		const key = this.#conversationKey(event.conversationId);
		if (key == null) {
			this.#releaseIncoming(event);
			return;
		}
		const conversation = store.getConv(this.#page.projection, key);
		if (conversation == null) {
			this.#releaseIncoming(event);
			return;
		}
		const mine = event.from === store.dirNick(this.#page.projection, conversation.dir);
		if (conversation.type === "dm") store.setDmLine(this.#page.projection, key, "live");
		// What the room states about itself folds in whatever else the line
		// carries, before any line is judged to be state alone and spared the
		// log: a statement with no words is exactly the line that is.
		if (event.facts?.subject != null) store.setSubject(this.#page.projection, key, event.facts.subject);
		if (event.facts?.lineBytes != null) store.setLineBytes(this.#page.projection, key, event.facts.lineBytes);
		if (event.facts?.bridge != null) store.setBridgeFacts(this.#page.projection, key, event.facts.bridge);
		if (event.facts?.carries != null) store.setCarries(this.#page.projection, key, event.facts.carries);
		if (event.presence?.kind === "typing") {
			applyTyping(this.#page, key, event.presence.name, event.presence.on);
			this.#releaseIncoming(event);
			return;
		}
		if (isStateOnlyRoomEvent(event.text, event.presence, event.attachments, event.change)) {
			this.#releaseIncoming(event);
			return;
		}
		const unshowable = lineNotShowable(event.from, event.text);
		if (unshowable != null) {
			store.deliver(this.#page.projection, key, store.sysItem(this.#page.projection, unshowable));
			this.#releaseIncoming(event);
			return;
		}
		this.#dispose(event, key, conversation, mine);
	}

	/** Settle one accepted line: classify its disposition once, then dispose
	 * of it in the one switch that owns custody. Every case says here what the
	 * event's occurrences become (held into the row it names, or released)
	 * so a disposition cannot enter the log without its custody decision
	 * beside it. The guard order above this point is the classification
	 * order: a typing or state-only line is decided before any change is
	 * read. */
	#dispose(event: PresentedLine<F>, key: string, conversation: Conv, mine: boolean): void {
		const projection = this.#page.projection;
		const history = store.historyOf(projection, key);
		const recorded = event.history == null
			? undefined
			: history.find((item) => item.kind === "chat" && sameArchiveCoordinates(item.history, event.history));
		const correlated = event.operation == null
			? undefined
			: history.find((item) =>
				item.kind === "chat" && (item.operation === event.operation || item.correlation === event.operation)
			);
		const found = correlated ?? recorded ??
			(event.lineId == null
				? undefined
				: history.find((item) =>
					item.kind === "chat" && item.lineId === event.lineId &&
					(event.history == null || item.history == null)
				));
		const named = found?.kind === "chat" ? found : undefined;
		const disposition: Disposition = event.change === "edited" && event.lineId != null
			? { kind: "edited", named }
			: event.change === "withdrawn" && event.lineId != null
			? { kind: "withdrawn", named }
			: event.change === "refiled" && event.lineId != null
			? { kind: "refiled", named }
			: event.system
			? { kind: "system", audience: event.presence?.kind === "roster" ? "here" : "shared" }
			: named != null &&
					(named.attachments ?? []).every((view) => this.#files?.retains(view.id)) &&
					sameAttachments(named.attachments ?? [], event.attachments)
			? { kind: "merged", named, correlated }
			: named != null
			? { kind: "replaced", named, correlated }
			: { kind: "arrived" };
		switch (disposition.kind) {
			case "edited": {
				if (disposition.named != null) {
					store.updateItem(projection, key, disposition.named.id, {
						text: event.text,
						edited: true,
						previewUrls: event.previewUrls.length === 0 ? undefined : event.previewUrls,
					});
				}
				this.#releaseIncoming(event);
				return;
			}
			case "withdrawn": {
				// The event is the room's authoritative outcome. Updating the item
				// also retires a matching composer intent while preserving any
				// newer input.
				if (disposition.named != null) {
					this.#files?.release(disposition.named.attachments ?? []);
					store.updateItem(projection, key, disposition.named.id, {
						withdrawn: true,
						withdrawal: undefined,
						withdrawalFailure: undefined,
						pendingEdit: undefined,
						editFailure: undefined,
						previewUrls: undefined,
					});
				}
				this.#releaseIncoming(event);
				return;
			}
			case "refiled": {
				if (disposition.named == null) {
					this.#releaseIncoming(event);
					return;
				}
				this.#files?.release(disposition.named.attachments ?? []);
				const attachments = this.#holdIncoming(event, conversation.dir);
				store.updateItem(projection, key, disposition.named.id, {
					text: event.text,
					previewUrls: event.previewUrls.length === 0 ? undefined : event.previewUrls,
					attachments: attachments.length === 0 ? undefined : attachments,
				});
				this.#openArrivingImages(key, event, mine, attachments);
				return;
			}
			case "system": {
				this.#presence.present(key, event.presence, event.text, performance.now(), (text) => {
					const item = store.sysItem(projection, text, disposition.audience);
					store.deliver(projection, key, item);
					return item.id;
				}, (id, text) => {
					if (!store.historyOf(projection, key).some((item) => item.kind === "sys" && item.id === id)) {
						return false;
					}
					store.updateItem(projection, key, id, { text });
					return true;
				});
				this.#releaseIncoming(event);
				return;
			}
			case "merged": {
				// Replayed authority carries fresh capability occurrences for the
				// same immutable bytes. Keep settled object URLs and transfer
				// state; only the duplicate occurrences need releasing. An
				// optimistic send also owns its presentation identity:
				// confirmation settles authority and send state, but must not
				// regroup or remount the bubble by replacing its local time.
				const { named, correlated } = disposition;
				store.updateItem(projection, key, named.id, {
					text: event.text,
					...(named.state == null && named.lineId == null && correlated == null ? { at: event.at } : {}),
					state: named.awaitingReceipt ? named.state : undefined,
					correlation: event.lineId != null || event.history != null ? undefined : named.correlation,
					...(event.history == null ? {} : { history: event.history }),
					...(event.lineId == null ? {} : { order: event.lineId, lineId: event.lineId }),
					...(event.editable ? { held: true } : {}),
					previewUrls: event.previewUrls,
				});
				this.#releaseIncoming(event);
				return;
			}
			case "replaced": {
				const { named, correlated } = disposition;
				const attachments = this.#holdIncoming(event, conversation.dir);
				if (attachments.length > 0) this.#files?.release(named.attachments ?? []);
				store.updateItem(projection, key, named.id, {
					text: event.text,
					...(named.state == null && named.lineId == null && correlated == null ? { at: event.at } : {}),
					state: named.awaitingReceipt ? named.state : undefined,
					correlation: event.lineId != null || event.history != null ? undefined : named.correlation,
					...(event.history == null ? {} : { history: event.history }),
					...(event.lineId == null ? {} : { order: event.lineId }),
					...(event.lineId == null ? {} : { lineId: event.lineId }),
					...(event.editable ? { held: true } : {}),
					...(attachments.length === 0 ? {} : { attachments }),
					previewUrls: event.previewUrls,
				});
				this.#openArrivingImages(key, event, mine, attachments);
				return;
			}
			case "arrived": {
				const attachments = this.#holdIncoming(event, conversation.dir);
				const item = store.chatItem(
					projection,
					event.from,
					event.text,
					mine,
					undefined,
					undefined,
					event.at,
				);
				store.deliver(projection, key, {
					...item,
					...(event.history == null ? {} : { history: event.history }),
					...(event.history == null || event.lineId == null ? {} : { order: event.lineId }),
					...(attachments.length === 0 ? {} : { attachments }),
					...(event.lineId == null ? {} : { lineId: event.lineId }),
					...(event.editable ? { held: true } : {}),
					...(event.previewUrls.length === 0 ? {} : { previewUrls: event.previewUrls }),
				});
				this.#openArrivingImages(key, event, mine, attachments);
				if (
					conversation.type === "dm" && !mine && projection.get().activeKey !== key &&
					!silencedFrom(event.from, false, projection.get().ignored)
				) maybeNotify(projection, event.from, event.text || event.attachments[0]?.name || "sent a file");
				return;
			}
			default: {
				// Unreachable while the union above is handled: a new kind fails
				// this typecheck before it can run. A kind's case must say its
				// custody when it is written.
				const unhandled: never = disposition;
				throw new Error(`Unhandled line disposition: ${unhandled as string}`);
			}
		}
	}

	#holdIncoming(event: PresentedLine<F>, directory: DirId): AttachmentView[] {
		if (event.attachments.length === 0) return [];
		const files = this.#files;
		if (files == null) throw new Error("the attached line projection has no file capability owner");
		const unavailable = this.#page.projection.get().dirs.get(directory)?.session === "disconnected"
			? EARLIER_CONNECTION_BYTES_UNAVAILABLE
			: undefined;
		return event.attachments.map((attachment) => files.hold(attachment, unavailable));
	}

	#releaseIncoming(event: PresentedLine<F>): void {
		if (event.attachments.length === 0) return;
		if (this.#files == null) throw new Error("the attached line projection has no file capability owner");
		this.#files.releaseIncoming(event.attachments);
	}

	#openArrivingImages(
		key: string,
		event: PresentedLine<F>,
		mine: boolean,
		views: readonly AttachmentView[],
	): void {
		const silenced = silencedFrom(event.from, mine, this.#page.projection.get().ignored);
		for (const [index, view] of views.entries()) {
			const attachment = event.attachments[index];
			if (attachment != null && fetchesOnArrival(attachment, silenced)) this.#files?.open(key, view.id);
		}
	}
}

function sameAttachments<F extends FileDescription>(
	views: readonly AttachmentView[],
	incoming: PresentedLine<F>["attachments"],
): boolean {
	return views.length === incoming.length && views.every((view, index) => {
		const attachment = incoming[index];
		return attachment != null && view.name === attachment.name && view.mime === attachment.mime &&
			view.size === attachment.size && (view.width ?? 0) === attachment.width &&
			(view.height ?? 0) === attachment.height;
	});
}
