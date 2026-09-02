// Runtime-only archive-share facets for one durable Rooms session.

import {
	type Behavior,
	Ref,
	retainCleanupFailures,
	retainSecondaryFailure,
	type Runtime,
	type Session,
} from "@glowcap/runtime";
import { DirectMessage } from "../lib/direct_message.ts";
import { parseRoomsSturdyref } from "../lib/locator.ts";
import {
	ALL_ARCHIVE_RECORDS,
	archiveBehavior,
	type ArchiveFilter,
	archiveFilterRow,
	type ArchivePage,
	MAX_ARCHIVE_READ,
	parseArchiveFilter,
	readArchive,
} from "../lib/archive/protocol.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../lib/limits.ts";
import {
	archiveConversationIdentity,
	archiveShareFilter,
	type ArchiveShareKind,
	parseArchiveShareKind,
} from "../lib/archive/handover.ts";
import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import type { LiveDirectory } from "./live.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import type { RealizeDirect } from "./realization.ts";
import { cleanupSettledBySessionClose, settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

export interface DurableArchiveShareView {
	id: string;
	directory: string;
	conversationId: string;
	from: string;
	status: "offered" | "reading" | "unavailable";
	error: string;
	kind: ArchiveShareKind;
	scopeConversation: string | null;
	custody: "live" | "durable";
	sturdyref: string;
}

export type ArchiveShareRedeemer = (sturdyref: string) => Promise<{
	session: Session;
	archive: Ref;
	close(): Promise<void>;
}>;

export function redeemArchiveShare(runtime: Runtime): ArchiveShareRedeemer {
	return async (sturdyref) => {
		const parsed = parseRoomsSturdyref(sturdyref);
		const session = await runtime.connect(parsed.locator);
		try {
			return {
				session,
				archive: await session.enliven(sturdyref),
				close: () => session.close(),
			};
		} catch (error) {
			throw await retainCleanupFailures(error, [() => session.close()]);
		}
	};
}

export function archiveShareCallbacks(shares: DurableRoomsArchiveShares): Pick<
	import("./directory_directs.ts").DirectRealizationCallbacks,
	"archiveShare" | "archiveOffer" | "closeConversation"
> {
	return {
		archiveShare: (held, owner, directory, kind, conversation, archive, from, fromRegistrationId) =>
			shares.receive(held, owner, directory, kind, conversation, archive, from, fromRegistrationId),
		archiveOffer: (held, directory, kind, conversation, sturdyref, from, fromRegistrationId) =>
			shares.receiveOffer(held, directory, kind, conversation, sturdyref, from, fromRegistrationId),
		closeConversation: (held, conversationId) => shares.releaseConversation(held.id, conversationId),
	};
}

interface HeldShare extends DurableArchiveShareView {
	owner: Session | null;
	archive: Ref | null;
	filter: ArchiveFilter;
	stopClose: () => void;
	released: boolean;
}

/** Host a read-only archive facet on the direct session that will carry it. */
function archiveShareFacet(archive: DurableRoomsArchive, scope: ArchiveFilter): Behavior {
	return archiveBehavior({
		put: () => Promise.reject(new Error("archive share is read-only")),
		read: (filter, after, limit) => archive.readPage(filter, after, limit),
	}, { scope, access: "read" });
}

export class DurableRoomsArchiveShares {
	readonly #archive: DurableRoomsArchive;
	readonly #redeem: ArchiveShareRedeemer;
	readonly #changed: () => void;
	readonly #shares = new Map<string, HeldShare>();
	#sequence = 0n;

	constructor(
		archive: DurableRoomsArchive,
		changed: () => void,
		redeem: ArchiveShareRedeemer = () => Promise.reject(new Error("durable archive offers are unavailable")),
	) {
		this.#archive = archive;
		this.#changed = changed;
		this.#redeem = redeem;
	}

	list(): DurableArchiveShareView[] {
		return [...this.#shares.values()].map((share) => this.#view(share));
	}

	async offer(
		directories: ReadonlyMap<string, LiveDirectory>,
		conversations: readonly WorkspaceConversation[],
		kind: ArchiveShareKind,
		conversationId: string,
		peer = "",
		realizeDirect: RealizeDirect = () => Promise.resolve(),
	): Promise<void> {
		const routed = await this.#route(directories, conversations, kind, conversationId, peer, realizeDirect);
		await this.#hand(routed.held, routed.line, routed.scope, routed.kind);
	}

	async offerDurable(
		directories: ReadonlyMap<string, LiveDirectory>,
		conversations: readonly WorkspaceConversation[],
		kind: ArchiveShareKind,
		conversationId: string,
		peer = "",
		realizeDirect: RealizeDirect = () => Promise.resolve(),
	): Promise<void> {
		const routed = await this.#route(directories, conversations, kind, conversationId, peer, realizeDirect);
		const id = crypto.randomUUID();
		const sturdyref = await this.#archive.issueShare(id, `${kind} archive share`, routed.scope);
		try {
			await routed.line.offerArchive(routed.held.id, routed.kind, routed.scope.conversation, sturdyref);
		} catch (error) {
			try {
				await this.#archive.revokeShare(id);
			} catch (cleanup) {
				throw retainSecondaryFailure(error, cleanup);
			}
			throw error;
		}
	}

	async #liveLine(
		find: () => { held: LiveDirectory; line: DirectMessage } | null,
		conversationId: string,
		realizeDirect: RealizeDirect,
	): Promise<{ held: LiveDirectory; line: DirectMessage }> {
		let found = find();
		if (found == null) {
			await realizeDirect(conversationId);
			found = find();
		}
		if (found == null) throw new Error("that direct conversation is not connected in this Rooms session");
		return found;
	}

	async #route(
		directories: ReadonlyMap<string, LiveDirectory>,
		conversations: readonly WorkspaceConversation[],
		kind: ArchiveShareKind,
		conversationId: string,
		peer: string,
		realizeDirect: RealizeDirect,
	): Promise<{ held: LiveDirectory; line: DirectMessage; scope: ArchiveFilter; kind: ArchiveShareKind }> {
		if (kind === "direct") {
			const live = await this.#liveLine(
				() => {
					for (const held of directories.values()) {
						const direct = held.directs.get(conversationId);
						if (direct == null) continue;
						return { held, line: direct.line };
					}
					return null;
				},
				conversationId,
				realizeDirect,
			);
			return {
				...live,
				scope: archiveShareFilter("direct", live.held.id, conversationId),
				kind: "direct",
			};
		}
		const room = conversations.find((entry) => entry.kind === "room" && entry.id === conversationId);
		if (room == null || room.kind !== "room") throw new Error("that room is not in this Rooms session");
		if (peer.trim() === "") throw new Error("name the member who should receive this archive account");
		const pipe = conversations.find((entry) =>
			entry.kind === "direct" && entry.directory === room.directory && !entry.closed &&
			entry.peer.toLowerCase() === peer.trim().toLowerCase()
		);
		if (pipe == null || pipe.kind !== "direct") {
			throw new Error("open a direct conversation with that member first");
		}
		const live = await this.#liveLine(
			() => {
				const held = directories.get(room.directory);
				const direct = held?.directs.get(pipe.id);
				if (held == null || direct == null) return null;
				return { held, line: direct.line };
			},
			pipe.id,
			realizeDirect,
		);
		return {
			...live,
			scope: archiveShareFilter(
				kind,
				live.held.id,
				archiveConversationIdentity({
					type: "room",
					persistId: room.id,
					id: room.name,
					held: room.held,
				}),
			),
			kind,
		};
	}

	async #hand(
		held: LiveDirectory,
		line: DirectMessage,
		scope: ArchiveFilter,
		kind: ArchiveShareKind,
	): Promise<void> {
		const facet = line.spawn(archiveShareFacet(this.#archive, scope));
		try {
			await line.handArchive(held.id, kind, scope.conversation, facet);
		} finally {
			line.releaseCapability(facet);
		}
	}

	receive(
		held: LiveDirectory,
		owner: Session,
		directory: unknown,
		kindRaw: unknown,
		conversation: unknown,
		archive: Ref,
		from: string,
		fromRegistrationId: string,
	): void {
		const release = (what: string) => {
			settleCapabilityCleanup(what, () => owner.release(archive));
		};
		let kind: ArchiveShareKind;
		let filter: ArchiveFilter;
		try {
			kind = parseArchiveShareKind(kindRaw);
			if (typeof directory !== "string" || directory !== held.id) {
				throw new Error("archive history must be scoped to this directory");
			}
			if (kind !== "standing" && typeof conversation !== "string") {
				throw new Error("archive history must name a conversation");
			}
			if (conversation !== null && typeof conversation !== "string") {
				throw new Error("archive history conversation must be a string or null");
			}
			filter = parseArchiveFilter(archiveFilterRow(archiveShareFilter(kind, directory, conversation)));
		} catch (error) {
			release("a malformed archive share capability could not be released");
			throw error;
		}
		const conversationId = held.directConversationByRegistration.get(fromRegistrationId) ?? null;
		if (conversationId == null) {
			release("a mis-scoped archive share capability could not be released");
			throw new Error("archive history was not shared over an accepted direct conversation");
		}
		if (this.#shares.size >= MAX_PENDING_ARCHIVE_SHARES) {
			release("an archive share at the session limit could not be released");
			throw new Error("this Rooms session has reached its archive-share limit");
		}
		this.#sequence += 1n;
		const id = `archive-share:${this.#sequence}`;
		const share: HeldShare = {
			id,
			directory: held.id,
			conversationId,
			from,
			status: "offered",
			error: "",
			kind,
			scopeConversation: filter.conversation,
			custody: "live",
			sturdyref: "",
			owner,
			archive,
			filter,
			stopClose: () => {},
			released: false,
		};
		share.stopClose = owner.onClose(() => {
			share.released = true;
			share.status = "unavailable";
			share.error = "The direct session carrying this archive share has ended.";
			this.#changed();
		});
		this.#shares.set(id, share);
		this.#changed();
	}

	receiveOffer(
		held: LiveDirectory,
		directory: unknown,
		kindRaw: unknown,
		conversation: unknown,
		sturdyref: unknown,
		from: string,
		fromRegistrationId: string,
	): void {
		const kind = parseArchiveShareKind(kindRaw);
		if (typeof directory !== "string" || directory !== held.id) {
			throw new Error("archive history must be scoped to this directory");
		}
		if (kind !== "standing" && typeof conversation !== "string") {
			throw new Error("archive history must name a conversation");
		}
		if (conversation !== null && typeof conversation !== "string") {
			throw new Error("archive history conversation must be a string or null");
		}
		if (typeof sturdyref !== "string") {
			throw new Error("a durable archive offer needs a sturdyref");
		}
		parseRoomsSturdyref(sturdyref);
		const filter = parseArchiveFilter(archiveFilterRow(archiveShareFilter(kind, directory, conversation)));
		const conversationId = held.directConversationByRegistration.get(fromRegistrationId) ?? null;
		if (conversationId == null) {
			throw new Error("archive history was not shared over an accepted direct conversation");
		}
		if (this.#shares.size >= MAX_PENDING_ARCHIVE_SHARES) {
			throw new Error("this Rooms session has reached its archive-share limit");
		}
		this.#sequence += 1n;
		const id = `archive-share:${this.#sequence}`;
		this.#shares.set(id, {
			id,
			directory: held.id,
			conversationId,
			from,
			status: "offered",
			error: "",
			kind,
			scopeConversation: filter.conversation,
			custody: "durable",
			sturdyref,
			owner: null,
			archive: null,
			filter,
			stopClose: () => {},
			released: false,
		});
		this.#changed();
	}

	async read(id: string, after: number): Promise<{ view: DurableArchiveShareView; page: ArchivePage }> {
		const share = this.#shares.get(id);
		if (share == null || share.released) throw new Error("that archive share is no longer available");
		if (share.status !== "reading" || share.error !== "") {
			share.status = "reading";
			share.error = "";
			this.#changed();
		}
		try {
			if (share.custody === "durable") {
				const redeemed = await this.#redeem(share.sturdyref);
				try {
					const page = await readArchive(
						redeemed.session,
						redeemed.archive,
						ALL_ARCHIVE_RECORDS,
						after,
						MAX_ARCHIVE_READ,
					);
					share.status = "offered";
					this.#changed();
					return { view: this.#view(share), page };
				} finally {
					await redeemed.close();
				}
			}
			if (share.owner == null || share.archive == null) {
				throw new Error("that archive share is no longer available");
			}
			const page = await readArchive(share.owner, share.archive, share.filter, after, MAX_ARCHIVE_READ);
			const view = this.#view(share);
			if (!page.more) this.#dispose(id, "consumed archive share");
			return { view, page };
		} catch (error) {
			share.status = "unavailable";
			share.error = error instanceof Error ? error.message : String(error);
			this.#changed();
			throw error;
		}
	}

	drop(id: string): void {
		this.#dispose(id, "declined archive share");
	}

	releaseConversation(directory: string, conversationId: string): void {
		for (const [id, share] of this.#shares) {
			if (share.custody === "durable") continue;
			if (share.directory === directory && share.conversationId === conversationId) {
				this.#dispose(id, "closed archive-share conversation");
			}
		}
	}

	releaseDirectory(directory: string): void {
		for (const [id, share] of this.#shares) {
			if (share.directory === directory) this.#dispose(id, "closed archive-share directory");
		}
	}

	close(): void {
		for (const id of [...this.#shares.keys()]) this.#dispose(id, "closed Rooms session");
	}

	#view(share: HeldShare): DurableArchiveShareView {
		return {
			id: share.id,
			directory: share.directory,
			conversationId: share.conversationId,
			from: share.from,
			status: share.status,
			error: share.error,
			kind: share.kind,
			scopeConversation: share.scopeConversation,
			custody: share.custody,
			sturdyref: share.sturdyref,
		};
	}

	#dispose(id: string, what: string): void {
		const share = this.#shares.get(id);
		if (share == null) return;
		if (share.custody === "durable") {
			this.#shares.delete(id);
			this.#changed();
			return;
		}
		if (!share.released) {
			try {
				if (share.owner != null && share.archive != null) share.owner.release(share.archive);
			} catch (error) {
				if (!cleanupSettledBySessionClose(error)) {
					share.status = "unavailable";
					share.error = `${what}: ${error instanceof Error ? error.message : error}`;
					this.#changed();
					return;
				}
			}
			share.released = true;
		}
		this.#shares.delete(id);
		settleCapabilityCleanup("archive-share close observer cleanup failed", () => share.stopClose());
		this.#changed();
	}
}
