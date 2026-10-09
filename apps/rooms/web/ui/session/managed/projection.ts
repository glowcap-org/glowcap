import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import { ROOM_SENDER } from "../../../../lib/protocol_data.ts";
// Intent names durable field coordinates. Activity describes live facts.
// Neither projection constructs capabilities or a legacy bearer checkpoint.
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import { dirId, isSessionConv, OPS_CAPS, type OpsCap, type SessionConv } from "../../types.ts";
import type { ArchiveShareView } from "../../archive_model.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { ActivityPage, ConversationIntent, WorkspaceSnapshot } from "./model.ts";
import { releaseActivity } from "./activity.ts";
import { AttachedLineProjection } from "../line_projection.ts";
import { type PresentedFile, presentFile } from "./files.ts";
import type { AttachedSessionFiles } from "../attached_files.ts";
import type { DirectoryMember, RoomEvent, RoomInfo } from "../../../../lib/directory_publications.ts";
import type { RoomFacts } from "../../../../lib/room/message.ts";
import type { Presence } from "../../../../lib/room/presence.ts";
import { applyRoomPresence } from "../../../../lib/room/presence.ts";
import { ignoredButYou, sharedHistoryOffered } from "../../../../lib/text/attached.ts";
import { applyTyping } from "../../typing.ts";
import { openRoomPolicy, privateRoomPolicy, type RoomPolicy } from "../../room_policy.ts";
import type { ArchiveCoordinates } from "../../../../lib/archive/protocol.ts";
import { operationSelection, operationsHeld } from "./operations_selection.ts";

interface Notice {
	kind: string;
	nick?: string;
	reason?: string;
	snapshot?: { rooms: RoomInfo[]; peers: DirectoryMember[]; truncated: boolean };
	event?: RoomEvent;
	from?: string;
	text?: string;
	name?: string;
	on?: boolean;
	policy?: RoomPolicy;
	listed?: boolean;
	marker?: { id: number; change: "said" | "edited" | "refiled" | "withdrawn" };
	metadata?: { presence?: Presence; facts?: RoomFacts };
	previewUrls?: string[];
	history?: ArchiveCoordinates;
}
export class ManagedProjection {
	readonly #page: RoomsPageContext;
	readonly #session: ManagedRoomsSession;
	readonly #files: AttachedSessionFiles<PresentedFile>;
	readonly #lines: AttachedLineProjection<PresentedFile>;
	readonly #resynchronizeHistory: () => void;
	readonly #archiveUnavailable: (key: string) => void;
	#stop: (() => void)[] = [];
	#revision: string | null = null;
	#active: string | null | undefined;
	readonly #identities = new Map<string, { conversation: string; inbox?: string }>();
	readonly #announcedShares = new Set<string>();
	readonly #operationSelections = new Map<OpsCap, string | null>();
	constructor(
		page: RoomsPageContext,
		session: ManagedRoomsSession,
		files: AttachedSessionFiles<PresentedFile>,
		resynchronizeHistory: () => void,
		archiveUnavailable: (key: string) => void,
	) {
		this.#page = page;
		this.#session = session;
		this.#files = files;
		this.#resynchronizeHistory = resynchronizeHistory;
		this.#archiveUnavailable = archiveUnavailable;
		this.#lines = new AttachedLineProjection(
			(id) => store.convByPersistId(page.projection, id)?.key ?? null,
			files,
			page,
		);
	}
	#endMembership(conversation: SessionConv, reason: string): void {
		const projection = this.#page.projection;
		const before = store.draftFor(projection, conversation.key);
		store.setRoomMembership(projection, conversation.key, "unavailable", reason);
		const after = store.draftFor(projection, conversation.key);
		if (before.changing != null && after.changing == null) {
			// The edit becomes an ordinary draft. Keep it over the last accepted
			// draft, including when the reader had not typed after choosing Edit.
			this.#session.drafts.stage(conversation.persistId, after.text);
		}
	}
	bind(): () => void {
		this.#stop = [
			this.#session.subscribe(() => this.apply()),
			this.#session.onActivity(async (delivery) => {
				const page = delivery.take();
				if (page.gap) this.#resynchronizeHistory();
				try {
					await this.#session.actions.receive(page);
					this.activity(page);
				} finally {
					releaseActivity(page);
				}
			}),
		];
		this.apply();
		return () => {
			for (const stop of this.#stop.splice(0)) stop();
		};
	}
	apply(): void {
		const current = this.#session.current;
		const projection = this.#page.projection;
		for (const cap of OPS_CAPS) {
			const selection = operationSelection(current?.intent, cap);
			if (this.#operationSelections.get(cap) !== selection) {
				this.#operationSelections.set(cap, selection);
				projection.set({ [cap]: null });
			}
		}
		projection.set({ managedAccess: this.#session.access });
		if (projection.get().navigationTarget !== this.#session.navigation.destination) {
			projection.set({ navigationTarget: this.#session.navigation.destination });
		}
		const effects = [...this.#session.recoverable, ...this.#session.actions.recoverable];
		const previous = projection.get().sessionEffects;
		if (effects.length !== previous.length || effects.some((id, i) => id !== previous[i])) {
			projection.set({ sessionEffects: effects });
		}
		if (current == null) {
			for (const row of [...projection.get().convs.values()]) store.forgetConv(projection, row.key);
			for (const id of [...projection.get().dirs.keys()]) store.forgetDir(projection, id);
			this.#revision = null;
			this.#active = undefined;
			this.#identities.clear();
			this.#announcedShares.clear();
			projection.set({ homeDir: null, opsHeld: operationsHeld() });
			return;
		}
		if (
			this.#revision === current.revision &&
			this.#active === (this.#session.navigation.selected ?? current.intent.active)
		) return;
		this.#topology(current);
		this.#revision = current.revision;
	}
	/** Lookup maps borrow presented conversations and archive shares for this pass.
	 * Retained line IDs get one scalar set per conversation, then retire. These
	 * indexes copy no rows, content or authority and never outlive projection. */
	#topology({ intent }: WorkspaceSnapshot): void {
		const projection = this.#page.projection;
		const first = this.#revision == null;
		const directories = new Set(intent.directories.map((row) => row.id));
		const conversations = new Set(intent.conversations.map((row) => row.id));
		const selected = store.activeConv(projection);
		let selectionReplaced = false;
		const presented = new Map<string, SessionConv>();
		for (const row of projection.get().convs.values()) {
			if (!directories.has(row.dir) || (isSessionConv(row) && !conversations.has(row.persistId))) {
				store.forgetConv(projection, row.key);
				if (isSessionConv(row)) {
					this.#identities.delete(row.persistId);
					this.#session.drafts.retire(row.persistId);
				}
			} else if (isSessionConv(row)) {
				presented.set(row.persistId, row);
			}
		}
		for (const id of projection.get().dirs.keys()) if (!directories.has(id)) store.forgetDir(projection, id);
		const homeDir = intent.directories.find((row) => row.home)?.id ?? null;
		if (projection.get().homeDir !== homeDir) projection.set({ homeDir: homeDir == null ? null : dirId(homeDir) });
		for (const row of intent.directories) {
			const id = dirId(row.id);
			store.openDir(projection, id, projection.get().dirs.get(id)?.locator ?? "");
			const held = projection.get().dirs.get(id)!;
			// Registration retirement is a live fact, even when cleanup succeeds.
			// A directory with no nickname can still be observed independently.
			const lostRegistration = row.nick !== "" && row.nick === held.requestedNick &&
				row.name == null && held.nick !== "";
			const registrationArrived = row.name != null && row.assignedNick != null && held.nick !== row.assignedNick;
			store.patchDir(projection, id, {
				requestedNick: row.nick,
				nick: row.assignedNick ?? "",
				standing: row.standing,
				...(registrationArrived
					? { session: "connected", reached: true, statusText: "" } as const
					: lostRegistration
					? { session: "reconnecting", statusText: managedText.directoryUnavailable } as const
					: {}),
			});
		}
		for (const row of intent.conversations) {
			const id = dirId(row.directory);
			let existing = presented.get(row.id) ?? null;
			const identity = conversationIdentity(row);
			const previous = this.#identities.get(row.id);
			if (existing != null && previous?.conversation !== identity) {
				selectionReplaced ||= existing.key === selected?.key;
				store.forgetConv(projection, existing.key);
				this.#session.drafts.retire(row.id);
				existing = null;
			}
			if (previous?.conversation !== identity || previous.inbox !== row.inbox) {
				this.#identities.set(row.id, { conversation: identity, inbox: row.inbox });
			}
			const conversation = existing ??
				(row.kind === "room"
					? store.ensureRoom(projection, id, row.name, {
						persistId: row.id,
						key: `room:${row.id}`,
						publicationId: row.publication,
						reconnect: row.reconnect,
					})
					: store.restoreDm(
						projection,
						id,
						row.peer,
						row.introduction?.registration ?? "",
						row.id,
						row.closed,
					));
			if (conversation == null) throw new Error("A managed conversation has no presentation directory");
			presented.set(row.id, conversation);
			if (row.kind === "room" && conversation.type === "room") {
				const grants = new Set(conversation.grants);
				if (row.files != null) grants.add("files");
				else grants.delete("files");
				if (row.topic != null) grants.add("topic");
				else grants.delete("topic");
				if (row.moderator != null) grants.add("steward");
				else grants.delete("steward");
				if (
					conversation.standing !== row.standing || conversation.reconnect !== row.reconnect ||
					conversation.linkToken !== (row.access ?? undefined) ||
					conversation.managerToken !== (row.control ?? undefined) ||
					conversation.stewardToken !== row.moderator || grants.size !== conversation.grants.size ||
					conversation.publicationId !== row.publication ||
					[...grants].some((grant) => !conversation.grants.has(grant))
				) {
					store.put(projection, {
						...conversation,
						grants,
						standing: row.standing,
						reconnect: row.reconnect,
						linkToken: row.access ?? undefined,
						managerToken: row.control ?? undefined,
						stewardToken: row.moderator,
						publicationId: row.publication,
					});
				}
				// A snapshot can skip the interval between two installed callbacks.
				// Their line numbers still belong to different memberships.
				const replaced = previous?.inbox != null && previous.inbox !== row.inbox;
				if ((row.seat == null || replaced) && conversation.membership === "joined") {
					this.#endMembership(conversation, managedText.membershipEnded);
					this.#files.markLost(managedText.membershipEnded, conversation.dir);
				}
			}
			if (row.kind === "direct" && conversation.type === "dm") {
				// Committed intent can reopen this exact peer's saved presentation.
				// Notifications cannot. Send authority and the installed callback
				// must both be held before the composer becomes live.
				const line = row.closed ? "closed" : row.access != null && row.inbox != null ? "live" : "introducing";
				if (conversation.line !== line) store.put(projection, { ...conversation, line });
			}
			const draft = store.draftFor(projection, conversation.key);
			const text = draft.changing == null ? this.#session.drafts.value(row.id, row.draft) : draft.text;
			if (draft.text !== text) store.setDraft(projection, text, conversation.key);
		}
		const state = projection.get();
		const opsHeld = operationsHeld(intent);
		if (OPS_CAPS.some((cap) => state.opsHeld[cap] !== opsHeld[cap])) projection.set({ opsHeld });
		if (state.keepHistory !== intent.keepHistory) projection.set({ keepHistory: intent.keepHistory });
		if (state.standing !== intent.standing) projection.set({ standing: intent.standing });
		if (state.ignored.size !== intent.ignored.length || intent.ignored.some((value) => !state.ignored.has(value))) {
			projection.set({ ignored: new Set(intent.ignored) });
		}
		const invites = intent.invitations.map((row) => ({
			id: row.id,
			dir: dirId(row.directory),
			way: "handed" as const,
			label: row.label,
			from: row.from,
			link: "",
		}));
		if (!sameRows(state.invites, invites)) projection.set({ invites });
		const priorShares = projection.get().archiveShares;
		const sharesById = new Map<string, ArchiveShareView>();
		for (const row of priorShares) sharesById.set(row.id, row);
		const archiveShares = (intent.archiveShares ?? []).map((row) => ({
			id: row.id,
			conversationKey: presented.get(row.channel)?.key ?? "",
			from: row.from,
			kind: row.kind,
			scopeConversation: row.conversation,
			custody: row.durable ? "durable" as const : "live" as const,
			copyable: row.durable,
			status: sharesById.get(row.id)?.status ?? "offered",
			error: sharesById.get(row.id)?.error ?? "",
		}));
		if (!sameRows(priorShares, archiveShares)) projection.set({ archiveShares });
		// A share that arrives while this page watches is announced once in its
		// conversation. The first projection only records what was already held.
		for (const share of archiveShares) {
			if (this.#announcedShares.has(share.id)) continue;
			this.#announcedShares.add(share.id);
			if (first || share.conversationKey === "" || share.status !== "offered") continue;
			store.deliver(
				projection,
				share.conversationKey,
				store.sysItem(projection, sharedHistoryOffered(share.from)),
			);
		}
		// Receipt acquisition may follow the live line notice. Authority, rather
		// than arrival order, decides when the exact displayed line is editable.
		for (const row of intent.conversations) {
			const conversation = presented.get(row.id);
			if (conversation == null) continue;
			const heldIds = new Set<number>();
			for (const line of row.lines ?? []) heldIds.add(line.id);
			for (const item of store.historyOf(projection, conversation.key)) {
				if (item.kind !== "chat" || item.lineId == null) continue;
				const held = heldIds.has(item.lineId);
				if (item.held !== held) store.updateItem(projection, conversation.key, item.id, { held });
			}
		}
		const local = this.#session.navigation.selected;
		const desired = local != null && intent.conversations.some((row) => row.id === local) ? local : intent.active;
		if (this.#active !== desired || selectionReplaced) {
			this.#active = desired;
			if (selected?.type === "directory" && store.getConv(projection, selected.key) != null) return;
			const active = desired == null ? null : presented.get(desired);
			if (active != null) store.switchTo(projection, active.key);
			else if (desired == null) projection.set({ activeKey: null });
		}
	}
	activity(page: ActivityPage): void {
		const event = page.event;
		if (event == null) return;
		const notice = event.notice as unknown as Notice;
		const projection = this.#page.projection;
		const directory = dirId(event.target.id);
		if (event.target.kind === "archive") {
			if (
				notice.kind === "unavailable" && this.#session.current?.intent.archive === event.target.id &&
				this.#session.permits("readArchive")
			) {
				this.#archiveUnavailable(event.target.id);
			}
			return;
		}
		if (event.target.kind === "discovery") {
			if (notice.kind === "discoverySnapshot" && notice.snapshot != null) {
				store.resetDirectoryDiscovery(projection, directory, notice.snapshot.rooms, notice.snapshot.peers);
				store.patchDir(projection, directory, { session: "connected", reached: true, statusText: "" });
			} else if (notice.kind === "discoveryChanged" && notice.event != null) {
				const change = notice.event;
				if (change.kind === "registered" || change.kind === "unregistered") {
					store.setDmable(
						projection,
						directory,
						change.name,
						change.registrationId,
						change.kind === "registered",
					);
				} else if (change.kind !== "truncated" && change.entry != null) {
					if (change.kind === "closed") store.dropLiveRoom(projection, directory, change.entry);
					else store.setLiveRoom(projection, directory, change.entry);
				}
			}
			return;
		}
		if (event.target.kind === "directory") {
			if (notice.kind === "registered") {
				store.patchDir(projection, directory, {
					nick: notice.nick ?? "",
					session: "connected",
					reached: true,
					statusText: "",
				});
			}
			return;
		}
		const conversation = store.convByPersistId(projection, event.target.id);
		if (conversation == null) return;
		if (notice.kind === "ready" && conversation.type === "dm") {
			return;
		}
		if (notice.kind === "ended") {
			if (conversation.type === "dm") store.put(projection, { ...conversation, line: "closed" });
			if (conversation.type === "room") {
				this.#endMembership(conversation, notice.reason ?? managedText.membershipEnded);
			}
			this.#files.markLost(notice.reason ?? managedText.membershipEnded, conversation.dir);
			return;
		}
		if (notice.kind === "policy" && notice.policy != null) {
			store.setRoomPolicy(projection, conversation.key, notice.policy);
			return;
		}
		if (notice.kind === "occupancy" && conversation.type === "room" && notice.listed != null) {
			store.setRoomPolicy(
				projection,
				conversation.key,
				notice.listed
					? (conversation.policy.visibility === "listed" ? conversation.policy : openRoomPolicy())
					: privateRoomPolicy(),
			);
			return;
		}
		if (notice.kind === "typing") {
			applyTyping(this.#page, conversation.key, notice.name ?? conversation.id, notice.on === true);
			return;
		}
		if (notice.kind !== "line") return;
		const joined = conversation.type === "room" && conversation.membership !== "joined";
		if (conversation.type === "room") store.setRoomMembership(projection, conversation.key, "joined", "");
		if (notice.metadata?.presence != null) {
			const members = projection.get().members.get(conversation.key) ?? new Map();
			const rosters = new Map(projection.get().members);
			rosters.set(conversation.key, applyRoomPresence(members, notice.metadata.presence));
			projection.set({ members: rosters });
		}
		const handles = event.files ?? [];
		const files: PresentedFile[] = [];
		// Transfer each wrapper before constructing its presentation source.
		// A partial conversion failure releases both converted and untouched rows.
		try {
			while (handles.length !== 0) files.push(presentFile(handles.shift()!));
		} catch (error) {
			for (const file of files) file.release();
			throw error;
		}
		this.#lines.apply({
			conversationId: event.target.id,
			from: notice.from ?? conversation.id,
			text: notice.text ?? "",
			at: Date.now(),
			lineId: notice.marker?.id ?? null,
			change: notice.marker?.change ?? null,
			editable: this.#session.current?.intent.conversations.find((row) =>
				row.id === event.target.id
			)?.lines?.some((line) =>
				line.id === notice.marker?.id
			) === true,
			history: notice.history ?? null,
			system: event.target.kind === "room" && notice.from === ROOM_SENDER,
			presence: notice.metadata?.presence,
			facts: notice.metadata?.facts,
			previewUrls: notice.previewUrls ?? [],
			attachments: files,
		});
		if (joined) {
			const own = store.dirNick(projection, conversation.dir);
			if (own !== "" && projection.get().ignored.has(own.toLowerCase())) {
				store.deliver(projection, conversation.key, store.sysItem(projection, ignoredButYou(own)));
			}
		}
	}
}

// Room authority may narrow without changing the conversation. An exact direct
// registration identifies the person across reconnects and reciprocal routes.
// Callback/opening/source replacement retires authority, not that person's
// history or draft. Without a witness, a changed route retires presentation.
function conversationIdentity(row: ConversationIntent): string {
	return JSON.stringify([
		row.kind,
		row.directory,
		row.kind === "room" ? [row.name, row.publication] : [row.peer, row.introduction?.registration ?? row.access],
	]);
}

function sameRows<T extends object>(left: readonly T[], right: readonly T[]): boolean {
	return left.length === right.length && left.every((row, index) => {
		const other = right[index];
		return other != null && Object.keys(row).length === Object.keys(other).length &&
			(Object.keys(row) as (keyof T)[]).every((key) => row[key] === other[key]);
	});
}
