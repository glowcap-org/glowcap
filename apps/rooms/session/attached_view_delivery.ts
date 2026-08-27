// Bounded event and snapshot delivery to one attached Rooms view.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@pancake/runtime";
import { attachmentArgs } from "../lib/attachment.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import type { ArchiveCoordinates } from "../lib/archive.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import { BLOB_CHUNK } from "../lib/limits.ts";
import { ROOMS_SESSION_CHANGED, ROOMS_SESSION_EVENT, type RoomsSessionFacet } from "../lib/rooms_session.ts";
import { READ } from "../lib/protocol.ts";
import type { Message } from "../lib/room_client.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { fitSessionSnapshot } from "./snapshot_wire.ts";

export const MAX_QUEUED_VIEW_EVENTS = 32;

export function attachedFileProxyBehavior(
	file: RuntimeAttachment,
	sessionFor: () => Session | null = currentSession,
): Behavior {
	return (verb, args) => {
		const session = sessionFor();
		if (session == null) throw new Error("a shared attachment is reachable only during a session turn");
		if (hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`shared attachment ${verb} does not take capability arguments`),
			);
		}
		if (
			verb !== READ || args.length !== 2 || typeof args[0] !== "bigint" ||
			args[0] < 0n || args[0] > BigInt(Number.MAX_SAFE_INTEGER) ||
			typeof args[1] !== "bigint" || args[1] <= 0n || args[1] > BigInt(BLOB_CHUNK)
		) throw new Error("shared attachment read takes a bounded offset and length");
		return file.read(Number(args[0]), Number(args[1]));
	};
}

export class AttachedViewDelivery {
	readonly #session: Session;
	readonly #observer: Ref;
	readonly #rights: RoomsSessionFacet;
	readonly #current: () => boolean;
	readonly #gapSnapshot: () => Argument[];
	readonly #reportFailure: (error: unknown) => void;
	#eventSource = crypto.randomUUID();
	#eventSequence = 0;
	#eventTail: Promise<void> = Promise.resolve();
	#eventQueued = 0;
	#eventGapReported = false;
	#snapshotSending = false;
	#pendingSnapshot: Argument[] | null = null;
	#retired = false;

	constructor(options: {
		session: Session;
		observer: Ref;
		rights: RoomsSessionFacet;
		current: () => boolean;
		gapSnapshot: () => Argument[];
		failed: (error: unknown) => void;
	}) {
		this.#session = options.session;
		this.#observer = options.observer;
		this.#rights = options.rights;
		this.#current = options.current;
		this.#gapSnapshot = options.gapSnapshot;
		this.#reportFailure = options.failed;
	}

	queueEvent(
		conversationId: string,
		message: Message,
		editable: boolean,
		files: RuntimeAttachment[],
		history: ArchiveCoordinates | null,
	): void {
		if (!this.#live()) return;
		if (this.#eventSequence === Number.MAX_SAFE_INTEGER) {
			this.#eventSource = crypto.randomUUID();
			this.#eventSequence = 0;
		}
		this.#eventSequence += 1;
		const source = this.#eventSource;
		const sequence = this.#eventSequence;
		if (this.#eventQueued === MAX_QUEUED_VIEW_EVENTS) {
			if (!this.#eventGapReported) {
				this.#eventGapReported = true;
				try {
					this.queueSnapshot(this.#gapSnapshot());
				} catch (error) {
					this.#fail(error);
				}
			}
			return;
		}
		this.#eventQueued += 1;
		const queued = this.#eventTail.then(async () => {
			if (!this.#live()) return;
			const args: Argument[] = [
				source,
				BigInt(sequence),
				conversationId,
				message.from,
				message.text,
				BigInt(Date.now()),
				message.lineId == null ? null : BigInt(message.lineId),
				message.change ?? null,
				editable && this.#rights !== "observe",
				history?.source ?? null,
				history?.generation ?? null,
				history?.id ?? null,
				message.system,
				message.presence == null ? null : JSON.stringify(message.presence),
				message.facts == null ? null : JSON.stringify(message.facts),
			];
			const proxies: Ref[] = [];
			try {
				for (const file of files) {
					const proxy = this.#session.spawn(attachedFileProxyBehavior(file));
					proxies.push(proxy);
					args.push(...attachmentArgs({
						name: file.name,
						mime: file.mime,
						size: file.size,
						width: file.width,
						height: file.height,
						blob: proxy,
					}));
				}
				await this.#session.tell(this.#observer, ROOMS_SESSION_EVENT, args);
			} finally {
				for (const proxy of proxies) {
					settleCapabilityCleanup(
						"shared attachment proxy release failed",
						() => this.#session.release(proxy),
					);
				}
			}
		});
		this.#eventTail = queued.catch((error) => this.#fail(error)).finally(() => {
			this.#eventQueued -= 1;
			if (this.#eventQueued === 0) this.#eventGapReported = false;
		});
	}

	queueSnapshot(args: Argument[]): void {
		if (!this.#live()) return;
		try {
			args = fitSessionSnapshot(args);
		} catch (error) {
			this.#fail(error);
			return;
		}
		if (this.#snapshotSending) {
			this.#pendingSnapshot = args;
			return;
		}
		this.#snapshotSending = true;
		void this.#sendSnapshots(args).catch((error) => this.#fail(error)).finally(() => {
			this.#snapshotSending = false;
			const pending = this.#pendingSnapshot;
			this.#pendingSnapshot = null;
			if (pending != null && this.#live()) this.queueSnapshot(pending);
		});
	}

	async #sendSnapshots(first: Argument[]): Promise<void> {
		let next: Argument[] | null = first;
		while (next != null && this.#live()) {
			await this.#session.tell(this.#observer, ROOMS_SESSION_CHANGED, next);
			next = this.#pendingSnapshot;
			this.#pendingSnapshot = null;
		}
	}

	#live(): boolean {
		return !this.#retired && this.#current();
	}

	#fail(error: unknown): void {
		if (this.#retired) return;
		this.#retired = true;
		this.#pendingSnapshot = null;
		this.#reportFailure(error);
	}
}
