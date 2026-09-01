// A stand-in for the session an attached controller talks to.
//
// The controller's own suite drives it, and so does anything else that needs a
// remote without a peer behind it: one fake here rather than one per file
// keeps the shape of the contract in a single place, and a member added to
// `AttachedRoomsRemote` is then answered once.
//
// Each subclass narrows one behaviour the base cannot express at the same
// time as the others: a command that parks mid-flight, a revision that keeps
// coming back stale, a snapshot that fails on a gap, room authority that is
// lost or still pending.

import type { RoomsSessionLineEvent, RoomsSessionSnapshot } from "../../lib/session/client.ts";
import type { RoomsOperationsSnapshot } from "../../lib/session/client.ts";
import type { AttachedRoomsRemote } from "../../web/ui/session/remote.ts";
import type { OperatorPage, OperatorRetireBatch } from "../../lib/operator.ts";
import type { Attachment, AttachmentSource } from "../../lib/attachment.ts";
import { roomsSessionSnapshot } from "./session_snapshot.ts";

export class FakeRemote implements AttachedRoomsRemote {
	snapshotValue: RoomsSessionSnapshot = roomsSessionSnapshot();
	changed: ((snapshot: RoomsSessionSnapshot) => void) | null = null;
	event: ((event: RoomsSessionLineEvent) => void) | null = null;
	calls: { id: string; base: number; name: string; args: string[] }[] = [];
	conflict = true;
	snapshots = 0;

	snapshot(): Promise<RoomsSessionSnapshot> {
		this.snapshots += 1;
		return Promise.resolve(this.snapshotValue);
	}

	siblingRefusal: Error | null = null;
	siblings: string[] = [];

	verifySibling(sturdyref: string): Promise<void> {
		this.siblings.push(sturdyref);
		return this.siblingRefusal === null ? Promise.resolve() : Promise.reject(this.siblingRefusal);
	}

	watch(changed: (snapshot: RoomsSessionSnapshot) => void, event: (event: RoomsSessionLineEvent) => void) {
		this.changed = changed;
		this.event = event;
		return Promise.resolve(this.snapshotValue);
	}

	command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		if (this.conflict) {
			this.conflict = false;
			this.snapshotValue = { ...this.snapshotValue, revision: 1 };
			return Promise.reject(new Error("session revision changed from 0 to 1"));
		}
		this.snapshotValue = {
			...this.snapshotValue,
			revision: base + 1,
			checkpoint: { ...this.snapshotValue.checkpoint, standing: args[0] ?? "" },
		};
		queueMicrotask(() => this.changed?.(this.snapshotValue));
		return Promise.resolve(base + 1);
	}

	publishPeeredRoom(id: string, base: number, intent: unknown): Promise<number> {
		return this.command(id, base, "publishPeeredRoom", [JSON.stringify(intent)]);
	}

	revokePeeredRoom(id: string, base: number, publication: string): Promise<number> {
		return this.command(id, base, "revokePeeredRoom", [publication]);
	}

	setTyping(): Promise<void> {
		return Promise.resolve();
	}

	editLine(id: string, base: number, conversation: string, lineId: number, text: string): Promise<number> {
		return this.command(id, base, "editLine", [conversation, String(lineId), text]);
	}

	withdrawLine(id: string, base: number, conversation: string, lineId: number): Promise<number> {
		return this.command(id, base, "withdrawLine", [conversation, String(lineId)]);
	}

	replace(id: string, base: number): Promise<number> {
		return this.command(id, base, "replace", []);
	}

	adoptWorkspace(id: string, base: number): Promise<number> {
		return this.command(id, base, "adoptWorkspace", []);
	}

	sendFiles(id: string, base: number, conversation: string, caption: string): Promise<number> {
		return this.command(id, base, "sendFiles", [conversation, caption]);
	}

	refileLine(
		id: string,
		base: number,
		conversation: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		_files: AttachmentSource[],
	): Promise<number> {
		return this.command(id, base, "refileLine", [conversation, String(lineId), caption, ...keep.map(String)]);
	}

	readHistory(): Promise<[]> {
		return Promise.resolve([]);
	}

	roomBridgeForm(): Promise<null> {
		return Promise.resolve(null);
	}

	operatorSnapshot(): Promise<never> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operatorPage(): Promise<OperatorPage> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operatorRetireMatching(): Promise<OperatorRetireBatch> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operationsSnapshot(): Promise<RoomsOperationsSnapshot> {
		return Promise.reject(new Error("no operations in this fake"));
	}

	shareArchiveHistory(): Promise<void> {
		return Promise.resolve();
	}

	offerDurableArchive(): Promise<void> {
		return Promise.resolve();
	}

	readArchiveShare(): ReturnType<AttachedRoomsRemote["readArchiveShare"]> {
		return Promise.reject(new Error("no archive shares in this fake"));
	}

	dropArchiveShare(): Promise<void> {
		return Promise.resolve();
	}

	listIssuedArchiveShares(): ReturnType<AttachedRoomsRemote["listIssuedArchiveShares"]> {
		return Promise.resolve([]);
	}

	revokeIssuedArchiveShare(): Promise<boolean> {
		return Promise.resolve(false);
	}

	fetchAttachment(): Promise<Uint8Array> {
		return Promise.resolve(new Uint8Array());
	}

	fetchArchivedAttachment(): Promise<Uint8Array> {
		return Promise.resolve(new Uint8Array());
	}

	releaseAttachment(_attachment: Attachment): void {}

	resolveEffect(): Promise<void> {
		return Promise.resolve();
	}

	resumeEffect(_id: string): Promise<number> {
		return Promise.resolve(this.snapshotValue.revision);
	}

	issueGrant(id: string, rights: "observe" | "interact" | "admin", label: string, history = false) {
		return Promise.resolve({ ...this.grantValue(id, rights, label), history });
	}

	changeGrant(
		id: string,
		patch: { rights?: "observe" | "interact" | "admin"; history?: boolean; suspended?: boolean; note?: string },
	) {
		return Promise.resolve({
			...this.grantValue(id, patch.rights ?? "interact", "Shared"),
			history: patch.history ?? false,
			suspended: patch.suspended ?? false,
			note: patch.note ?? "",
		});
	}

	setGrantAccess(id: string, rights: "observe" | "interact" | "admin") {
		return Promise.resolve(this.grantValue(id, rights, "Shared"));
	}

	setGrantHistory(id: string, history: boolean) {
		return Promise.resolve({ ...this.grantValue(id, "interact", "Shared"), history });
	}

	suspendGrant(id: string, note = "") {
		return Promise.resolve({ ...this.grantValue(id, "interact", "Shared"), suspended: true, note });
	}

	resumeGrant(id: string) {
		return Promise.resolve(this.grantValue(id, "interact", "Shared"));
	}

	/** One shape for every grant this fake answers with, so a field added to the
	 * view is added here once. */
	protected grantValue(id: string, rights: "observe" | "interact" | "admin", label: string) {
		return {
			id,
			rights,
			label,
			history: rights === "admin",
			suspended: false,
			note: "",
			sturdyref: `ocapn://session.id/s/${id}`,
		};
	}

	revokeGrant(_id: string): Promise<void> {
		return Promise.resolve();
	}
}

export class DraftRemote extends FakeRemote {
	started!: () => void;
	finish!: () => void;
	readonly commandStarted = new Promise<void>((resolve) => this.started = resolve);
	readonly commandFinish = new Promise<void>((resolve) => this.finish = resolve);

	override async command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.started();
		await this.commandFinish;
		return await super.command(id, base, name, args);
	}
}

export class StaleRevisionRemote extends FakeRemote {
	constructor() {
		super();
		this.conflict = false;
	}

	override command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		return Promise.resolve(base + 1);
	}
}

export class GapSnapshotFailureRemote extends FakeRemote {
	override snapshot(): Promise<RoomsSessionSnapshot> {
		return Promise.reject(new Error("snapshot unavailable"));
	}
}

export class LostRoomAuthorityRemote extends FakeRemote {
	readonly lost = new Set<string>();

	override command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		if (name !== "ensureRoomLink" && name !== "takeRoomModerator") return super.command(id, base, name, args);
		if (!this.lost.has(id)) {
			this.lost.add(id);
			const room = this.snapshotValue.checkpoint.conversations.find((entry) => entry.kind === "room");
			if (room?.kind === "room") {
				this.snapshotValue = {
					...this.snapshotValue,
					revision: base + 1,
					checkpoint: {
						...this.snapshotValue.checkpoint,
						conversations: this.snapshotValue.checkpoint.conversations.map((entry) =>
							entry.id !== room.id ? entry : {
								...entry,
								link: "ocapn://directory.example/s/room-link",
								...(name === "takeRoomModerator"
									? { steward: "ocapn://directory.example/s/steward-link" }
									: {}),
							}
						),
					},
				};
			}
			queueMicrotask(() => this.changed?.(this.snapshotValue));
			return Promise.reject(new Error("the result response was lost"));
		}
		return Promise.resolve(this.snapshotValue.revision);
	}
}

export class PendingRoomAuthorityRemote extends FakeRemote {
	resumed: string[] = [];

	override resumeEffect(id: string): Promise<number> {
		this.resumed.push(id);
		const room = this.snapshotValue.checkpoint.conversations.find((entry) => entry.kind === "room");
		this.snapshotValue = {
			...this.snapshotValue,
			revision: this.snapshotValue.revision + 1,
			checkpoint: {
				...this.snapshotValue.checkpoint,
				conversations: this.snapshotValue.checkpoint.conversations.map((entry) =>
					entry.id === room?.id ? { ...entry, link: "ocapn://directory.example/s/recovered-link" } : entry
				),
			},
			pendingEffects: [],
			pendingEffectDetails: [],
		};
		queueMicrotask(() => this.changed?.(this.snapshotValue));
		return Promise.resolve(this.snapshotValue.revision);
	}
}

/** A remote whose command does not answer until the test lets it, and whose
 * snapshot reports that command as pending the whole time. It is how a durable
 * operation actually looks while it is under way: in the session's ledger, with
 * this tab awaiting it. */
export class HeldCommandRemote extends FakeRemote {
	readonly opened = Promise.withResolvers<string>();
	readonly answer = Promise.withResolvers<void>();
	refuse: Error | null = null;

	override async command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		this.snapshotValue = {
			...this.snapshotValue,
			pendingEffectDetails: [{ id, kind: "say", subject: name, phase: "prepared" }],
		};
		this.opened.resolve(id);
		await this.answer.promise;
		if (this.refuse !== null) throw this.refuse;
		this.snapshotValue = { ...this.snapshotValue, revision: base + 1, pendingEffectDetails: [] };
		queueMicrotask(() => this.changed?.(this.snapshotValue));
		return base + 1;
	}
}
