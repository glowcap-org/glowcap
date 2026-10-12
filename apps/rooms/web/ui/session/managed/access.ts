// Held management is independent of workspace use. Inventory is descriptive.
// A row becomes editable only through an independently retained control.
import type {
	RoomsManagedAcquisition,
	RoomsManagedApplication,
	RoomsManagedAttenuation,
	RoomsManagedControl,
	RoomsManagedEdit,
	RoomsManagedIssuance,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsPermission } from "../../../../lib/session_content_data.ts";
import { AcquisitionConflict, submitAcquisition } from "./acquisition.ts";

export interface PolicyView {
	permissions: RoomsPermission[];
	bounds: { key: string; operator: string; value: string }[];
}
export interface GrantView {
	slot: number;
	generation: string;
	revision: string;
	label: string;
	status: "active" | "paused" | "revoked";
	effectiveStatus: "active" | "paused" | "revoked";
	configured: PolicyView;
	ceiling: PolicyView;
	delegationDepth: number;
}
export interface ManagementView {
	available: boolean;
	status?: "active" | "paused" | "revoked";
	revision?: string;
	inspect?: boolean;
	pause?: boolean;
	resume?: boolean;
	revoke?: boolean;
	delegateControl?: boolean;
	editCeiling?: PolicyView | null;
	issueCeiling?: PolicyView | null;
}
export interface ManagementPowers {
	inspect: boolean;
	pause: boolean;
	resume: boolean;
	revoke: boolean;
	delegateControl: boolean;
	editCeiling: RoomsPermission[] | null;
	issueCeiling: RoomsPermission[] | null;
}
export const NO_MANAGEMENT: ManagementPowers = {
	inspect: false,
	pause: false,
	resume: false,
	revoke: false,
	delegateControl: false,
	editCeiling: null,
	issueCeiling: null,
};
/** The issuer keeps the control that issuance returns, so it holds every power
 * the source can pass on: powers are fixed at issuance, and a narrower one is
 * shared later by attenuation. A source that cannot delegate passes none. */
export function keptPowers(
	source: ManagementView,
	ceilings: { editCeiling: RoomsPermission[] | null; issueCeiling: RoomsPermission[] | null },
): ManagementPowers {
	if (source.delegateControl !== true) return { ...NO_MANAGEMENT };
	return {
		inspect: source.inspect === true,
		pause: source.pause === true,
		resume: source.resume === true,
		revoke: source.revoke === true,
		delegateControl: true,
		editCeiling: ceilings.editCeiling,
		issueCeiling: ceilings.issueCeiling,
	};
}
/** What a new access's own permissions can later be changed up to: both the
 * source's edit limit and its issuance limit bound the new grant's ceiling. */
export function editableUnder(source: ManagementView): RoomsPermission[] | undefined {
	const edit = source.editCeiling?.permissions;
	const issue = source.issueCeiling?.permissions;
	return edit == null || issue == null ? undefined : edit.filter((permission) => issue.includes(permission));
}
export function grantIdentity(row: GrantView): string {
	return `${row.slot}:${row.generation}`;
}
export interface HeldControl {
	readonly id: string;
	readonly handle: RoomsManagedControl;
	grant: GrantView | null;
	powers: ManagementView;
	pending?: PendingEdit;
	saving?: RoomsManagedAcquisition;
	saveTask?: Promise<void>;
	saved?: boolean;
	/** What this viewer last committed, for a control that cannot inspect. */
	committed?: { label?: string; permissions?: RoomsPermission[] };
	forgetTask?: Promise<void>;
}
/** The local workspace's own control: the root every other access descends from. */
export const OWN_CONTROL = "current";
/** The label this viewer knows the control's access to have. */
export function knownLabel(control: HeldControl): string {
	return control.grant?.label ?? control.committed?.label ?? "";
}
/** What a held control is called: its access's label, or what it is. */
export function controlName(
	control: HeldControl,
	names: { readonly held: string; readonly ownControl: string; readonly revokedName: string },
): string {
	return knownLabel(control) ||
		(control.id === OWN_CONTROL ? names.ownControl : control.powers.available ? names.held : names.revokedName);
}
/** The status this viewer knows the access to have. A control that describes
 * nothing has had its access, or an access above it, revoked. */
export function knownStatus(control: HeldControl): GrantView["status"] | undefined {
	if (!control.powers.available) return "revoked";
	return control.grant?.effectiveStatus ?? control.powers.status;
}
/** The permissions this viewer knows the control's access to have. */
export function knownPermissions(control: HeldControl): readonly RoomsPermission[] {
	return control.grant?.configured.permissions ?? control.committed?.permissions ?? [];
}
export interface PendingIssue {
	readonly id: string;
	readonly source: HeldControl;
	readonly request: RoomsManagedIssuance;
	readonly label: string;
	phase: "prepared" | "committed" | "conflict" | "uncertain";
	reason: string;
	access?: RoomsManagedWorkspace;
	control?: HeldControl;
	uninspected?: RoomsManagedControl;
}
export type EditIntent =
	| { kind: "policy"; permissions: RoomsPermission[] }
	| { kind: "label"; label: string }
	| { kind: "pause" | "resume" | "revoke" };
export interface PendingEdit {
	readonly intent: EditIntent;
	readonly base: string;
	readonly request: RoomsManagedEdit;
	phase: "prepared" | "committed" | "conflict" | "uncertain";
	reason: string;
}

/** This owner keeps wrappers through UI unmounts. Its saved row names select
 * actual strong control fields through Rust, never inventory identities. */
export class ManagedAccess {
	readonly #application: RoomsManagedApplication;
	readonly #workspace: RoomsManagedWorkspace;
	readonly #report: (error: unknown) => void;
	readonly #controls = new Map<string, HeldControl>();
	readonly #preparing = new Set<HeldControl>();
	readonly #holding = new Set<string>();
	readonly #listeners = new Set<() => void>();
	readonly #jobs = new Set<Promise<unknown>>();
	readonly #submitting = new Map<HeldControl, Promise<PendingEdit>>();
	#submittingIssue: Promise<PendingIssue> | null = null;
	#version = 0;
	#retired = false;
	#closed = false;
	#issue: PendingIssue | null = null;
	#issuing = false;

	constructor(
		application: RoomsManagedApplication,
		workspace: RoomsManagedWorkspace,
		report: (error: unknown) => void,
	) {
		this.#application = application;
		this.#workspace = workspace;
		this.#report = report;
	}
	get held(): readonly HeldControl[] {
		return [...this.#controls.values()];
	}
	get issue(): PendingIssue | null {
		return this.#issue;
	}
	subscribe = (listener: () => void): () => void => {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	};
	getVersion = (): number => this.#version;
	#changed(): void {
		this.#version++;
		for (const listener of this.#listeners) {
			try {
				listener();
			} catch (error) {
				this.#report(error);
			}
		}
	}
	#checkOpen(): void {
		if (this.#closed) throw new Error("Access management is closed");
	}
	#accept<T extends { free(): void }>(handle: T): T {
		if (this.#closed) {
			handle.free();
			throw new Error("Access management is closed");
		}
		return handle;
	}
	#track<T>(job: Promise<T>): Promise<T> {
		const tracked = job.finally(() => this.#jobs.delete(tracked));
		this.#jobs.add(tracked);
		return tracked;
	}
	hold(id: string, handle: RoomsManagedControl): Promise<HeldControl> {
		return this.#track(this.#hold(id, handle));
	}
	async #hold(id: string, handle: RoomsManagedControl): Promise<HeldControl> {
		this.#checkOpen();
		if (this.#controls.has(id) || this.#holding.has(id)) throw new Error("This control is already held");
		this.#holding.add(id);
		try {
			const powers: ManagementView = await handle.describe();
			// A control without Inspect remains held and usable for its explicit
			// powers, but cannot manufacture a target description for the editor.
			const grant: GrantView | null = powers.available && powers.inspect ? await handle.inspect() : null;
			const held = { id, handle, grant, powers };
			this.#checkOpen();
			this.#controls.set(id, held);
			this.#changed();
			return held;
		} finally {
			this.#holding.delete(id);
		}
	}
	async restore(ids: readonly string[], report: (id: string, error: unknown) => void): Promise<void> {
		for (const id of ids) {
			if (this.#closed) break;
			if (this.#controls.has(id)) continue;
			try {
				const handle: RoomsManagedControl = await this.#application.savedControl(id);
				try {
					(await this.hold(id, handle)).saved = true;
				} catch (error) {
					handle.free();
					throw error;
				}
			} catch (error) {
				report(id, error);
			}
		}
	}
	refresh(control: HeldControl): Promise<void> {
		return this.#track(this.#refresh(control));
	}
	async #refresh(control: HeldControl): Promise<void> {
		this.#checkOpen();
		const powers: ManagementView = await control.handle.describe();
		const current: GrantView | null = powers.available && powers.inspect ? await control.handle.inspect() : null;
		this.#checkOpen();
		if (current != null && control.grant != null && grantIdentity(current) !== grantIdentity(control.grant)) {
			throw new Error("The held control changed its target generation");
		}
		// A control that stops inspecting, as a revoked one does, still knows
		// what its access was called and allowed when it last could.
		if (current == null && control.grant != null) {
			control.committed = { label: control.grant.label, permissions: [...control.grant.configured.permissions] };
		}
		control.powers = powers;
		control.grant = current;
		this.#changed();
	}
	async inventory(control: HeldControl, cursor?: Uint8Array): Promise<{
		rows: GrantView[];
		cursor: Uint8Array | null;
	}> {
		this.#checkOpen();
		return await this.#track(control.handle.inventory(cursor));
	}
	async prepareSave(id: string, control: RoomsManagedControl) {
		this.#checkOpen();
		return await this.#track(
			this.#workspace.prepareSaveControl(id, control).then((request) => this.#accept(request)),
		);
	}
	save(control: HeldControl): Promise<void> {
		this.#checkOpen();
		if (control.saved) return Promise.resolve();
		return control.saveTask ??= this.#track(this.#save(control)).finally(() => {
			delete control.saveTask;
		});
	}
	async #save(control: HeldControl): Promise<void> {
		const saving: RoomsManagedAcquisition = control.saving ?? await this.prepareSave(control.id, control.handle);
		control.saving = saving;
		const outcome = await submitAcquisition(saving);
		this.#checkOpen();
		saving.free();
		delete control.saving;
		control.saved = outcome === "committed";
		this.#changed();
		if (outcome === "conflict") throw new AcquisitionConflict();
	}
	prepareIssue(
		source: HeldControl,
		permissions: RoomsPermission[],
		label: string,
		paused: boolean,
		depth: number,
		ceilings: { editCeiling: RoomsPermission[] | null; issueCeiling: RoomsPermission[] | null },
	): Promise<void> {
		return this.#track(
			this.#prepareIssue(source, permissions, label, paused, depth, keptPowers(source.powers, ceilings)),
		);
	}
	async #prepareIssue(
		source: HeldControl,
		permissions: RoomsPermission[],
		label: string,
		paused: boolean,
		depth: number,
		powers: ManagementPowers,
	): Promise<void> {
		this.#checkOpen();
		if (this.#issue != null || this.#issuing) {
			throw new Error("Recover the retained issuance before creating another access branch");
		}
		this.#issuing = true;
		try {
			const base = source.powers.revision;
			if (base == null) throw new Error("This management control is unavailable");
			const request: RoomsManagedIssuance = this.#accept(
				await source.handle.prepareIssue(
					base,
					// The smallest immutable ceiling covering initial use and the
					// explicitly selected future editing and issuance authority.
					JSON.stringify({
						configured: permissions,
						ceiling: [
							...new Set([...permissions, ...powers.editCeiling ?? [], ...powers.issueCeiling ?? []]),
						],
					}),
					label,
					paused,
					depth,
					JSON.stringify(powers),
				),
			);
			this.#issue = { id: crypto.randomUUID(), source, request, label, phase: "prepared", reason: "" };
			this.#changed();
		} finally {
			this.#issuing = false;
		}
	}
	submitIssue(): Promise<PendingIssue> {
		this.#checkOpen();
		return this.#submittingIssue ??= this.#track(this.#submitIssue()).finally(() => {
			this.#submittingIssue = null;
		});
	}
	async #submitIssue(): Promise<PendingIssue> {
		const issue = this.#issue;
		if (issue == null) throw new Error("There is no retained issuance");
		if (issue.phase === "conflict") return issue;
		try {
			if (issue.phase !== "committed") {
				const output: {
					status: "committed" | "conflict" | "uncertain";
					reason?: string;
					access?: RoomsManagedWorkspace;
					control?: RoomsManagedControl;
				} = await issue.request.submitOutcome();
				if (this.#closed) {
					output.access?.free();
					output.control?.free();
					throw new Error("Access management is closed");
				}
				issue.phase = output.status;
				issue.reason = output.reason ?? "";
				if (output.status === "committed") {
					issue.access = output.access!;
					issue.uninspected = output.control!;
				}
			}
			if (issue.uninspected != null) {
				issue.control = await this.hold(issue.id, issue.uninspected);
				delete issue.uninspected;
				// Issuing advanced the source's own revision. Without reading it
				// again, the next issuance from this source would refuse as a
				// change someone else made.
				await this.#refresh(issue.source).catch(() => {
					// tolerant: a stale source only costs the next issuance one
					// conflict, and that refusal's review reads it again.
				});
			}
		} catch (error) {
			// The original issuance receipt remains the authority for another
			// attempt, including a result projection or publication failure.
			if (issue.phase !== "committed") issue.phase = "uncertain";
			issue.reason = error instanceof Error ? error.message : String(error);
		}
		return issue;
	}
	finishIssue(): void {
		this.#checkOpen();
		if (this.#submittingIssue != null) throw new Error("The original issuance is still submitting");
		const issue = this.#issue;
		if (issue == null) return;
		if (issue.phase !== "committed" && issue.phase !== "conflict") {
			throw new Error("Recover the original issuance first");
		}
		if (issue.uninspected != null) throw new Error("Recover the returned control before finishing issuance");
		if (issue.control != null && !issue.control.saved) {
			throw new Error("Save the issued control before finishing issuance");
		}
		issue.request.free();
		issue.access?.free();
		this.#issue = null;
		this.#changed();
	}
	prepare(control: HeldControl, intent: EditIntent, base: string): Promise<void> {
		return this.#track(this.#prepare(control, intent, base));
	}
	async #prepare(control: HeldControl, intent: EditIntent, base: string): Promise<void> {
		this.#checkOpen();
		if (control.pending != null || this.#preparing.has(control)) {
			throw new Error("Recover the retained edit before preparing another one");
		}
		this.#preparing.add(control);
		try {
			const request: RoomsManagedEdit = intent.kind === "policy"
				? await control.handle.preparePolicy(base, JSON.stringify(intent.permissions))
				: intent.kind === "label"
				? await control.handle.prepareLabel(base, intent.label)
				: intent.kind === "pause"
				? await control.handle.preparePause(base)
				: intent.kind === "resume"
				? await control.handle.prepareResume(base)
				: await control.handle.prepareRevoke(base);
			control.pending = { intent, base, request: this.#accept(request), phase: "prepared", reason: "" };
			this.#changed();
		} finally {
			this.#preparing.delete(control);
		}
	}
	submit(control: HeldControl): Promise<PendingEdit> {
		this.#checkOpen();
		const existing = this.#submitting.get(control);
		if (existing != null) return existing;
		const task = this.#track(this.#submit(control)).finally(() => this.#submitting.delete(control));
		this.#submitting.set(control, task);
		return task;
	}
	async #submit(control: HeldControl): Promise<PendingEdit> {
		const pending = control.pending;
		if (pending == null) throw new Error("There is no retained edit to submit");
		if (pending.phase === "committed" || pending.phase === "conflict") return pending;
		try {
			const outcome: { status: "committed" | "conflict" | "uncertain"; reason?: string } = await pending.request
				.submitOutcome();
			pending.phase = outcome.status;
			pending.reason = outcome.reason ?? "";
			// The owner committed exactly this intent, so it is known now even
			// before (or without) a fresh inspection of the target.
			if (outcome.status === "committed") {
				const intent = pending.intent;
				if (intent.kind === "label") {
					control.committed = { ...control.committed, label: intent.label };
					if (control.grant != null) control.grant = { ...control.grant, label: intent.label };
				} else if (intent.kind === "policy") {
					control.committed = { ...control.committed, permissions: intent.permissions };
					if (control.grant != null) {
						control.grant = {
							...control.grant,
							configured: { ...control.grant.configured, permissions: intent.permissions },
						};
					}
				}
				this.#changed();
			}
		} catch (error) {
			pending.phase = "uncertain";
			pending.reason = error instanceof Error ? error.message : String(error);
		}
		return pending;
	}
	finish(control: HeldControl): void {
		this.#checkOpen();
		if (this.#submitting.has(control)) throw new Error("The original edit is still submitting");
		const pending = control.pending;
		if (pending == null) return;
		if (pending.phase !== "committed" && pending.phase !== "conflict") {
			throw new Error("Recover the original edit before discarding its request");
		}
		pending.request.free();
		delete control.pending;
		this.#changed();
	}
	async reapply(control: HeldControl): Promise<void> {
		const pending = control.pending;
		if (pending?.phase !== "conflict") throw new Error("Only a confirmed conflict permits reapplication");
		await this.refresh(control);
		const revision = control.powers.revision;
		if (revision == null) throw new Error("The held control is unavailable");
		this.finish(control);
		await this.prepare(control, pending.intent, revision);
	}
	/** A link to a narrower control of its own for someone else. Sharing the
	 * held control itself would hand over every power it has. */
	share(control: HeldControl, powers: ManagementPowers): Promise<string> {
		this.#checkOpen();
		return this.#track(this.#share(control, powers));
	}
	async #share(control: HeldControl, powers: ManagementPowers): Promise<string> {
		const request: RoomsManagedAttenuation = this.#accept(
			await control.handle.prepareAttenuation(JSON.stringify(powers)),
		);
		try {
			const narrower: RoomsManagedControl = this.#accept(await request.submit());
			try {
				return await narrower.publish();
			} finally {
				narrower.free();
			}
		} finally {
			request.free();
		}
	}
	attach(id: string, uri: string): Promise<HeldControl> {
		return this.#track(this.#attach(id, uri));
	}
	async #attach(id: string, uri: string): Promise<HeldControl> {
		this.#checkOpen();
		const handle = await this.#application.attachControl(uri);
		try {
			return await this.hold(id, handle);
		} catch (error) {
			handle.free();
			throw error;
		}
	}
	/** Stop holding a management control: release its saved row, then its
	 * handle. The access it manages is untouched. Revoking is what ends that.
	 * Each attempt reads the current row, so a retry after a lost reply finds
	 * the row already released and only lets go of the handle. */
	forget(control: HeldControl): Promise<void> {
		this.#checkOpen();
		if (control.id === OWN_CONTROL) return Promise.reject(new Error("This workspace's own access stays held."));
		if (control.pending != null || this.#submitting.has(control) || this.#issue?.source === control) {
			return Promise.reject(new Error("Finish or discard this access's unfinished change first."));
		}
		if (control.saveTask != null) return Promise.reject(new Error("Wait for this access to finish saving."));
		return control.forgetTask ??= this.#track(this.#forget(control)).finally(() => {
			delete control.forgetTask;
		});
	}
	async #forget(control: HeldControl): Promise<void> {
		// Another writer can move the workspace between read and commit; each
		// conflict rereads it, and three in a row report the conflict.
		for (let attempt = 1;; attempt++) {
			const release: RoomsManagedAcquisition | null = await this.#workspace.prepareForgetControl(control.id);
			if (release == null) break;
			this.#accept(release);
			try {
				if (await submitAcquisition(release) === "committed") break;
			} finally {
				release.free();
			}
			if (attempt === 3) throw new AcquisitionConflict();
		}
		this.#checkOpen();
		this.#controls.delete(control.id);
		control.saving?.free();
		control.handle.free();
		this.#changed();
	}
	stop(): void {
		this.#closed = true;
	}
	async close(): Promise<void> {
		if (this.#retired) return;
		this.#closed = true;
		await Promise.allSettled([...this.#jobs]);
		if (this.#retired) return;
		this.#retired = true;
		this.#issue?.request.free();
		this.#issue?.access?.free();
		this.#issue?.uninspected?.free();
		this.#issue = null;
		for (const control of this.#controls.values()) {
			control.saving?.free();
			control.pending?.request.free();
			control.handle.free();
		}
		this.#controls.clear();
	}
}
