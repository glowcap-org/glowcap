// The Rooms process's retained capability occurrences, and their owner-aware
// release paths. This is deliberately not a generic Host reference table.

import type { Ref, Session } from "@glowcap/runtime";
import { MAX_OPERATOR_PAGE } from "../../lib/limits.ts";
import type { RoomServerContext } from "../context.ts";
import { type Introduction, type Member, type PendingUpload, type RoomState } from "../registry.ts";
import { leaveRoom } from "../presence.ts";
import { dropSignalExchange, revokeIntroduction } from "../introductions.ts";
import { notifyPublicRoom } from "../discovery.ts";
import {
	type OperatorRowPage,
	type OperatorRowSource,
	queryPage,
	queryWords,
	searchText,
	sourceMatches,
} from "./page.ts";
import type { OperatorReferenceKind } from "../../lib/operator_vocabulary.ts";

export type { OperatorReferenceKind } from "../../lib/operator_vocabulary.ts";

export interface OperatorReferenceRow {
	id: string;
	kind: OperatorReferenceKind;
	owner: string;
	room: string;
	member: string;
	detail: string;
}

type ReferenceId = (ref: Ref) => string;

interface ReferenceSweep {
	readonly iterator: Iterator<OperatorRowSource<OperatorReferenceRow>>;
	readonly query: string;
	readonly kind: OperatorReferenceKind | null;
	readonly words: readonly string[];
	revision: bigint;
	remaining: number;
}

function pendingId(id: string): string {
	return `ref-pending-${id}`;
}

function pendingPeeringActive(ctx: RoomServerContext, id: string): boolean {
	for (const pending of ctx.peering.rows()) if (pending.id === id) return true;
	return false;
}

function retained(
	idFor: ReferenceId,
	ref: Ref,
	row: Omit<OperatorReferenceRow, "id">,
	release: () => boolean,
	active: () => boolean,
): OperatorRowSource<OperatorReferenceRow> {
	const id = idFor(ref);
	const complete = { ...row, id };
	return {
		id,
		text: searchText(id, row.kind, row.owner, row.room, row.member, row.detail),
		kind: row.kind,
		build: () => complete,
		retire: release,
		active,
	};
}

function releaseMember(ctx: RoomServerContext, state: RoomState, member: Member): boolean {
	return leaveRoom(ctx, state, member.session, { ended: "An operator ended this room membership." });
}

function releaseLine(ctx: RoomServerContext, member: Member, ref: Ref, at: number): boolean {
	const held = member.lines[at];
	if (held?.ref !== ref) return false;
	member.lines.splice(at, 1);
	ctx.journal.release(held.session, ref, "operator-released room line authority");
	ctx.operator.noteChange();
	return true;
}

function releaseUpload(ctx: RoomServerContext, state: RoomState, upload: PendingUpload): boolean {
	if (!state.uploads.get(upload.member)?.has(upload) || upload.spent) return false;
	ctx.files.dropUpload(state, upload);
	ctx.operator.noteChange();
	return true;
}

type RoomReferenceTarget =
	| { readonly kind: "membership" }
	| { readonly kind: "line"; readonly ref: Ref; readonly at: number }
	| { readonly kind: "upload"; readonly upload: PendingUpload };

/** One compact indexed room occurrence. Release and liveness are prototype
 * methods over a tagged owner, so a 100k-line room retains no per-row closures
 * or second projection object in the operator index. */
class RoomReferenceSource implements OperatorRowSource<OperatorReferenceRow> {
	#ctx: RoomServerContext;
	#id: string;
	#state: RoomState;
	#member: Member;
	#target: RoomReferenceTarget;
	#roomText: string;
	#memberText: string;

	constructor(
		ctx: RoomServerContext,
		id: string,
		state: RoomState,
		member: Member,
		target: RoomReferenceTarget,
	) {
		this.#ctx = ctx;
		this.#id = id;
		this.#state = state;
		this.#member = member;
		this.#target = target;
		this.#roomText = state.name.toLowerCase();
		this.#memberText = member.nick.toLowerCase();
	}

	reset(id: string, state: RoomState, member: Member, target: RoomReferenceTarget): this {
		this.#id = id;
		if (this.#state !== state) this.#roomText = state.name.toLowerCase();
		if (this.#member !== member) this.#memberText = member.nick.toLowerCase();
		this.#state = state;
		this.#member = member;
		this.#target = target;
		return this;
	}

	get kind(): OperatorReferenceKind {
		if (this.#target.kind === "membership") return "membership";
		if (this.#target.kind === "line") return "line";
		return "upload";
	}

	get id(): string {
		return this.#id;
	}

	get text(): string {
		return searchText(
			this.#id,
			this.kind,
			this.#owner(),
			this.#roomText,
			this.#memberText,
			this.#detail(),
		);
	}

	matches(words: readonly string[]): boolean {
		const kind = this.kind;
		const owner = this.#owner();
		const detail = this.#detail().toLowerCase();
		for (const word of words) {
			if (
				!this.#id.includes(word) && !kind.includes(word) && !owner.includes(word) &&
				!this.#roomText.includes(word) && !this.#memberText.includes(word) && !detail.includes(word)
			) return false;
		}
		return true;
	}

	build(): OperatorReferenceRow {
		return {
			id: this.#id,
			kind: this.kind,
			owner: this.#owner(),
			room: this.#state.name,
			member: this.#member.nick,
			detail: this.#detail(),
		};
	}

	retire(): boolean {
		if (this.#target.kind === "membership") return releaseMember(this.#ctx, this.#state, this.#member);
		if (this.#target.kind === "line") {
			return releaseLine(this.#ctx, this.#member, this.#target.ref, this.#target.at);
		}
		return releaseUpload(this.#ctx, this.#state, this.#target.upload);
	}

	active(): boolean {
		if (!this.#state.members.includes(this.#member)) return false;
		if (this.#target.kind === "membership") return true;
		if (this.#target.kind === "line") return this.#member.lines[this.#target.at]?.ref === this.#target.ref;
		return this.#state.uploads.get(this.#member)?.has(this.#target.upload) === true &&
			!this.#target.upload.spent;
	}

	#owner(): string {
		if (this.#target.kind === "membership") return "room membership";
		if (this.#target.kind === "line") return "room line history";
		return "pending upload";
	}

	#detail(): string {
		if (this.#target.kind === "membership") {
			const held = this.#member.lines.length;
			// A membership with nothing held says so in words. "0 recent line
			// holds" reads as a counter beside a row an operator is deciding
			// whether to release, and the decision turns on whether releasing
			// takes anything else with it.
			return `${held === 0 ? "no" : held} recent line hold${held === 1 ? "" : "s"}`;
		}
		if (this.#target.kind === "line") return "recent editable line authority";
		return `${this.#target.upload.file.name} (${this.#target.upload.size} bytes)`;
	}
}

function* roomReferences(
	ctx: RoomServerContext,
	state: RoomState,
	idFor: ReferenceId,
): Iterable<OperatorRowSource<OperatorReferenceRow>> {
	let cursor: RoomReferenceSource | null = null;
	const source = (id: string, member: Member, target: RoomReferenceTarget): RoomReferenceSource => {
		if (cursor == null) {
			const made = new RoomReferenceSource(ctx, id, state, member, target);
			cursor = made;
			return made;
		}
		return cursor.reset(id, state, member, target);
	};
	// Membership retirement splices this owner array. Walk it backwards so the
	// next member cannot shift behind the iterator after its predecessor leaves.
	for (let memberAt = state.members.length - 1; memberAt >= 0; memberAt -= 1) {
		const member = state.members[memberAt];
		for (let at = member.lines.length - 1; at >= 0; at -= 1) {
			const ref = member.lines[at].ref;
			yield source(
				idFor(ref),
				member,
				{ kind: "line", ref, at },
			);
		}
		for (const upload of state.uploads.get(member) ?? []) {
			if (upload.ref === null || upload.spent) continue;
			yield source(
				idFor(upload.ref),
				member,
				{ kind: "upload", upload },
			);
		}
		// The membership owns every line and upload above. Retire children first
		// so one bounded sweep act removes exactly the one match it reports rather
		// than cascading over sources the iterator can no longer count.
		yield source(
			idFor(member.inbox),
			member,
			{ kind: "membership" },
		);
	}
}

function* introductionChildReferences(
	ctx: RoomServerContext,
	intro: Introduction,
	idFor: ReferenceId,
): Iterable<OperatorRowSource<OperatorReferenceRow>> {
	for (const [registrationId, ref] of intro.inboxes) {
		const peer = ctx.live.introductionsById.get(registrationId)?.nick ?? "departed registration";
		yield retained(
			idFor,
			ref,
			{
				kind: "offered-inbox",
				owner: "directory registration",
				room: "",
				member: intro.nick,
				detail: `inbox offered to ${peer} (${registrationId})`,
			},
			() => {
				if (intro.inboxes.get(registrationId) !== ref) return false;
				intro.inboxes.delete(registrationId);
				ctx.journal.release(intro.registrar, ref, "operator-released offered inbox");
				ctx.operator.noteChange();
				return true;
			},
			() =>
				ctx.live.introductionsById.get(intro.registrationId) === intro &&
				intro.inboxes.get(registrationId) === ref,
		);
	}
	if (intro.signaling !== null) {
		const ref = intro.signaling;
		yield retained(
			idFor,
			ref,
			{
				kind: "signaling",
				owner: "directory registration",
				room: "",
				member: intro.nick,
				detail: "WebRTC signaling inbox",
			},
			() => {
				if (intro.signaling !== ref) return false;
				intro.signaling = null;
				ctx.journal.release(intro.registrar, ref, "operator-released signaling inbox");
				ctx.operator.noteChange();
				return true;
			},
			() => ctx.live.introductionsById.get(intro.registrationId) === intro && intro.signaling === ref,
		);
	}
}

function introductionReference(
	ctx: RoomServerContext,
	intro: Introduction,
	idFor: ReferenceId,
): OperatorRowSource<OperatorReferenceRow> {
	return retained(
		idFor,
		intro.inbox,
		{
			kind: "registration",
			owner: "directory registration",
			room: "",
			member: intro.nick,
			detail: "registration inbox and name claim",
		},
		() => revokeIntroduction(ctx, intro.nick, intro.registrar),
		() => ctx.live.introductionsById.get(intro.registrationId) === intro,
	);
}

/** Walk the current reference owners without materializing or retaining a
 * second inventory. Stable IDs live in the weak identity table, while every
 * release closure is borrowed from the owner row yielded on this walk. */
function* currentReferences(
	ctx: RoomServerContext,
	idFor: ReferenceId,
): Iterable<OperatorRowSource<OperatorReferenceRow>> {
	for (const state of ctx.live.rooms.values()) yield* roomReferences(ctx, state, idFor);
	for (const entry of ctx.live.publicRooms.values()) {
		if (entry.kind !== "foreign") continue;
		yield retained(
			idFor,
			entry.room,
			{
				kind: "foreign-room",
				owner: "foreign room publication",
				room: entry.name,
				member: "",
				detail: `${entry.proof} publication from ${entry.origin}`,
			},
			() => {
				const removed = ctx.live.forgetForeignRoom(entry.id);
				if (removed === null) return false;
				notifyPublicRoom(ctx, removed, "closed", null);
				return true;
			},
			() => ctx.live.publicRoomById(entry.id) === entry,
		);
	}
	for (const pending of ctx.peering.rows()) {
		const id = pendingId(pending.id);
		yield {
			id,
			text: searchText(
				id,
				"pending-peering",
				"pending foreign publication",
				pending.name,
				pending.proof,
				pending.origin,
			),
			kind: "pending-peering",
			build: () => ({
				id,
				kind: "pending-peering",
				owner: "pending foreign publication",
				room: pending.name,
				member: "",
				detail: `${pending.proof} publication from ${pending.origin}`,
			}),
			retire: () => ctx.peering.remove(pending.id),
			active: () => pendingPeeringActive(ctx, pending.id),
		};
	}
	// A registration retirement also drops exchanges aimed at that registration;
	// enumerate those children before the registration owners below.
	for (const [id, exchange] of ctx.live.signalExchanges) {
		yield retained(
			idFor,
			exchange.reply,
			{
				kind: "signal-exchange",
				owner: "signaling exchange",
				room: "",
				member: "",
				detail: `in-flight exchange ${id}`,
			},
			() => {
				if (!ctx.live.signalExchanges.has(id)) return false;
				dropSignalExchange(ctx.live, id, "operator released signaling exchange");
				return true;
			},
			() => ctx.live.signalExchanges.get(id)?.reply === exchange.reply,
		);
	}
	// Registration retirement owns not only its own signaling capability and
	// collected inboxes, but every inbox another registration offered to it.
	// Walk every child across the registry before any registration owner. An
	// interleaved per-registration walk lets retiring an early registration
	// erase children in a later one before the bounded sweep can account for
	// them, making `remaining` disagree with the live inventory.
	for (const intro of ctx.live.introductions.values()) yield* introductionChildReferences(ctx, intro, idFor);
	for (const intro of ctx.live.introductions.values()) yield introductionReference(ctx, intro, idFor);
}

/** The identity namespace and traversal of one Rooms operator capability.
 * Server construction owns an instance; tests create isolated instances. */
export class OperatorReferenceInventory {
	readonly #ctx: RoomServerContext;
	readonly #ids = new WeakMap<Ref, string>();
	#nextId = 1n;
	readonly #sweeps = new WeakMap<Session, ReferenceSweep>();
	constructor(ctx: RoomServerContext) {
		this.#ctx = ctx;
	}

	readonly #idFor: ReferenceId = (ref) => {
		let id = this.#ids.get(ref);
		if (id == null) {
			id = `ref-${this.#nextId}`;
			this.#nextId += 1n;
			this.#ids.set(ref, id);
		}
		return id;
	};

	/** Every retained reference as a borrowed traversal. A page scans the live
	 * owners directly and retains only its bounded answer; unrelated operator
	 * revisions never allocate a process-sized reference index. */
	faces(): Iterable<OperatorRowSource<OperatorReferenceRow>> {
		return currentReferences(this.#ctx, this.#idFor);
	}

	page(
		offset: number,
		limit: number,
		query = "",
		kind: OperatorReferenceKind | null = null,
	): OperatorRowPage<OperatorReferenceRow> {
		if (
			!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 ||
			limit > MAX_OPERATOR_PAGE
		) throw new Error("operator reference page cursor or limit is out of range");
		const sources = function* (inventory: OperatorReferenceInventory) {
			for (const source of inventory.faces()) {
				if ((kind === null || source.kind === kind) && source.active?.() !== false) yield source;
			}
		};
		return queryPage(sources(this), query, offset, limit);
	}

	/** Retire one bounded continuation of a reference search. One initial scan
	 * establishes the count; a live owner iterator then continues across calls.
	 * The sweep is O(N) while retaining one cursor rather than one source object
	 * per reference. An unrelated operator mutation invalidates and recounts it. */
	retireMatching(
		session: Session,
		query: string,
		kind: OperatorReferenceKind | null,
		limit: number,
	): { retired: number; remaining: number; refused: string } {
		const revision = this.#ctx.operator.current;
		let sweep = this.#sweeps.get(session);
		if (sweep == null || sweep.revision !== revision || sweep.query !== query || sweep.kind !== kind) {
			const words = queryWords(query);
			let remaining = 0;
			for (const source of this.faces()) {
				if (
					(kind === null || source.kind === kind) && source.active?.() !== false &&
					(words.length === 0 || sourceMatches(source, words))
				) remaining += 1;
			}
			sweep = {
				iterator: this.faces()[Symbol.iterator](),
				query,
				kind,
				words,
				revision,
				remaining,
			};
			this.#sweeps.set(session, sweep);
		}

		let retired = 0;
		let refused = "";
		let complete = false;
		while (retired < limit) {
			const next = sweep.iterator.next();
			if (next.done) {
				complete = true;
				sweep.remaining = 0;
				break;
			}
			const source = next.value;
			if (kind !== null && source.kind !== kind) continue;
			if (sweep.words.length > 0 && !sourceMatches(source, sweep.words)) continue;
			if (source.active?.() === false) {
				sweep.remaining -= 1;
				continue;
			}
			try {
				if (source.retire?.()) {
					retired += 1;
					sweep.remaining -= 1;
				} else if (refused === "") refused = "a retained reference changed before it could be released";
			} catch (error) {
				if (refused === "") refused = error instanceof Error ? error.message : String(error);
			}
		}
		sweep.revision = this.#ctx.operator.current;
		if (complete || sweep.remaining === 0) {
			this.#sweeps.delete(session);
		}
		return { retired, remaining: Math.max(0, sweep.remaining), refused };
	}

	resetSweep(session: Session): void {
		this.#sweeps.delete(session);
	}

	release(id: string): void {
		for (const reference of currentReferences(this.#ctx, this.#idFor)) {
			if (reference.id !== id) continue;
			if (reference.retire?.()) return;
			break;
		}
		throw new Error("that retained reference is no longer present");
	}
}
