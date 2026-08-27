// Runtime-only archive-share facets for one durable Rooms session.

import { type Behavior, Ref, type Session } from "@pancake/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	archiveBehavior,
	type ArchiveFilter,
	archiveFilterRow,
	type ArchivePage,
	MAX_ARCHIVE_READ,
	parseArchiveFilter,
	readArchive,
} from "../lib/archive.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../lib/limits.ts";
import type { LiveDirectory } from "./live.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import { cleanupSettledBySessionClose, settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

export interface DurableArchiveShareView {
	id: string;
	directory: string;
	conversationId: string;
	from: string;
	status: "offered" | "reading" | "unavailable";
	error: string;
}

interface HeldShare extends DurableArchiveShareView {
	owner: Session;
	archive: Ref;
	filter: ArchiveFilter;
	stopClose: () => void;
	released: boolean;
}

/** Host a read-only archive facet on the direct session that will carry it. */
export function archiveShareFacet(archive: DurableRoomsArchive, scope: ArchiveFilter): Behavior {
	return archiveBehavior({
		put: () => Promise.reject(new Error("archive share is read-only")),
		read: (filter, after, limit) => archive.readPage(filter, after, limit),
	}, { scope, access: "read" });
}

export class DurableRoomsArchiveShares {
	readonly #archive: DurableRoomsArchive;
	readonly #changed: () => void;
	readonly #shares = new Map<string, HeldShare>();
	#sequence = 0n;

	constructor(archive: DurableRoomsArchive, changed: () => void) {
		this.#archive = archive;
		this.#changed = changed;
	}

	list(): DurableArchiveShareView[] {
		return [...this.#shares.values()].map(({ id, directory, conversationId, from, status, error }) => ({
			id,
			directory,
			conversationId,
			from,
			status,
			error,
		}));
	}

	receive(
		held: LiveDirectory,
		owner: Session,
		directory: unknown,
		conversation: unknown,
		archive: Ref,
		from: string,
		fromRegistrationId: string,
	): void {
		const release = (what: string) => {
			settleCapabilityCleanup(what, () => owner.release(archive));
		};
		if (
			typeof directory !== "string" || typeof conversation !== "string" || typeof from !== "string" ||
			directory !== held.id
		) {
			release("an archive share capability could not be released");
			throw new Error("archive history must be scoped to this direct conversation");
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
		// The sender's persisted conversation ID scopes the facet it handed over.
		// Round-trip through the archive parser once at admission so this metadata
		// cannot smuggle an unbounded or malformed query into later reads.
		let filter: ArchiveFilter;
		try {
			filter = parseArchiveFilter(archiveFilterRow({
				...ALL_ARCHIVE_RECORDS,
				kind: "line",
				conversationKind: "direct",
				directory: held.id,
				conversation,
			}));
		} catch (error) {
			release("a malformed archive share capability could not be released");
			throw error;
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

	async read(id: string, after: number): Promise<{ view: DurableArchiveShareView; page: ArchivePage }> {
		const share = this.#shares.get(id);
		if (share == null || share.released) throw new Error("that archive share is no longer available");
		if (share.status !== "reading" || share.error !== "") {
			share.status = "reading";
			share.error = "";
			this.#changed();
		}
		try {
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
		};
	}

	#dispose(id: string, what: string): void {
		const share = this.#shares.get(id);
		if (share == null) return;
		if (!share.released) {
			try {
				share.owner.release(share.archive);
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
