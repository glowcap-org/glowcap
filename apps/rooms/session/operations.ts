// Operations-capability custody for one durable Rooms session.

import { Ref, type Session } from "@glowcap/runtime";
import * as z from "zod/mini";
import type { Directory } from "../lib/directory.ts";
import { type DiagnosticRow, snapshotDiagnostics } from "../lib/diagnostics.ts";
import type { BridgeGateway } from "../lib/bridge/gateway.ts";
import {
	addBridgeLease,
	closeBridgeConnection,
	openBridgeConnection,
	removeBridgeLease,
	snapshotBridgeGateway,
} from "../lib/bridge/gateway_client.ts";
import { listenerDown, ListenerOptionsSchema, type ListenerRow, listenerUp, listListeners } from "../lib/listeners.ts";
import {
	clearOperatorTrouble,
	disconnectSession,
	giveRoomManager,
	giveStewardship,
	type OperatorCategory,
	type OperatorPage,
	operatorPage,
	type OperatorReferenceKind,
	type OperatorResetScope,
	type OperatorRetireBatch,
	operatorRetireMatching,
	type OperatorSnapshot,
	releaseOperatorReference,
	removeOperatorRoom,
	resetOperatorScope,
	revokeNick,
	revokeRoomAuthority,
	revokeRoomLink,
	revokeStewardship,
	snapshotOperator,
	subscribeOperator,
} from "../lib/operator.ts";
import type { RoomsSessionState } from "../lib/rooms_state.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

interface HeldOperation {
	directoryId: string;
	swiss: string;
	session: Session;
	capability: Ref;
	stopWatch: (() => void) | null;
}

interface ConnectedDirectory {
	directory: Directory;
}

type OperationCredential = RoomsSessionState["capabilities"]["operations"][number];

export type DurableOperationsSnapshot =
	| { capability: "listeners"; rows: ListenerRow[] }
	| { capability: "diagnostics"; rows: DiagnosticRow[] }
	| { capability: "irc"; snapshot: BridgeGateway };

const MAX_OPERATION_JSON_CHARS = 128 * 1024;

function jsonValue<T>(raw: string, what: string, schema: z.ZodMiniType<T>): T {
	if (raw.length > MAX_OPERATION_JSON_CHARS) throw new Error(`${what} are too large`);
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error(`${what} are not JSON`);
	}
	const parsed = z.safeParse(schema, decoded);
	if (!parsed.success) throw new Error(`${what} are incomplete or invalid`);
	return parsed.data;
}

export class DurableRoomsOperations {
	readonly #held = new Map<string, HeldOperation>();
	readonly #issueKeys = new Set<string>();
	readonly #setIssue: (subject: string, error: unknown | null) => boolean;
	readonly #invalidated: (scope: string) => void;

	constructor(setIssue: (subject: string, error: unknown | null) => boolean, invalidated: (scope: string) => void) {
		this.#setIssue = setIssue;
		this.#invalidated = invalidated;
	}

	operatorEffect(scope: string, action: string, args: string[]): () => Promise<void> {
		const held = this.#operator(scope);
		const effect = this.#operatorAction(held, action, args);
		return async () => {
			await effect();
			this.#invalidated(scope);
		};
	}

	issueRoomManager(scope: string, roomIdentity: string): Promise<string> {
		const held = this.#operator(scope);
		return giveRoomManager(held.session, held.capability, roomIdentity);
	}

	async snapshot(
		scope: string,
		capability: DurableOperationsSnapshot["capability"],
	): Promise<DurableOperationsSnapshot> {
		const held = this.#capability(scope, capability);
		if (capability === "listeners") {
			return { capability, rows: await listListeners(held.session, held.capability) };
		}
		if (capability === "diagnostics") {
			return { capability, rows: await snapshotDiagnostics(held.session, held.capability) };
		}
		return { capability, snapshot: await snapshotBridgeGateway(held.session, held.capability) };
	}

	operationEffect(scope: string, capability: string, action: string, args: string[]): () => Promise<void> {
		if (capability === "irc") return this.#ircEffect(scope, action, args);
		if (capability === "diagnostics") {
			throw new Error(
				"the diagnostics capability is inspect-only; use its snapshot and the Rooms operator to act",
			);
		}
		if (capability === "operator") {
			throw new Error(
				"Rooms operator mutations use the operator command, which preserves their typed action scope",
			);
		}
		if (capability === "peering") {
			throw new Error("peering mutations use durable publication intents, not raw operations calls");
		}
		if (capability === "viz") {
			throw new Error("the visualizer capability is reconciled from saved session configuration");
		}
		if (capability !== "listeners") throw new Error(`unknown shared operations capability "${capability}"`);
		const held = this.#capability(scope, capability);
		if (action === "up" && args.length === 2) {
			const options = jsonValue(args[1], "listener up options", ListenerOptionsSchema);
			return async () => {
				await listenerUp(held.session, held.capability, args[0], options);
				this.#invalidated(scope);
			};
		}
		if (action === "down" && args.length === 1) {
			const id = Number(args[0]);
			if (!Number.isSafeInteger(id) || id <= 0) throw new Error("listener down needs a positive listener id");
			return async () => {
				await listenerDown(held.session, held.capability, id);
				this.#invalidated(scope);
			};
		}
		throw new Error(`shared listener action ${action} has invalid arguments`);
	}

	#ircEffect(scope: string, action: string, args: string[]): () => Promise<void> {
		const held = this.#capability(scope, "irc");
		if (action === "openConnection" && args.length === 1) {
			return async () => {
				await openBridgeConnection(held.session, held.capability, args[0]);
				this.#invalidated(scope);
			};
		}
		if (action === "closeConnection" && args.length === 1 && args[0] !== "") {
			return async () => {
				await closeBridgeConnection(held.session, held.capability, args[0]);
				this.#invalidated(scope);
			};
		}
		if (action === "removeLease" && args.length === 2 && args[0] !== "" && args[1] !== "") {
			return async () => {
				await removeBridgeLease(held.session, held.capability, args[0], args[1]);
				this.#invalidated(scope);
			};
		}
		if (action === "addLease" && args.length === 2 && args[0] !== "") {
			return async () => {
				await addBridgeLease(held.session, held.capability, args[0], args[1]);
				this.#invalidated(scope);
			};
		}
		throw new Error(`shared bridge gateway action ${action} has invalid arguments`);
	}

	#operatorAction(held: HeldOperation, action: string, args: string[]): () => Promise<void> {
		if (action === "revokeRoomLink" && args.length === 1) {
			return () => revokeRoomLink(held.session, held.capability, args[0]);
		}
		if (
			action === "revokeRoomAuthority" && args.length === 2 &&
			(args[0] === "room" || args[0] === "steward" || args[0] === "manager")
		) {
			const kind = args[0];
			return () => revokeRoomAuthority(held.session, held.capability, kind, args[1]);
		}
		if (action === "revokeNick" && args.length === 2) {
			return () => revokeNick(held.session, held.capability, args[0], args[1]);
		}
		if (action === "disconnectSession" && args.length === 1) {
			return () => disconnectSession(held.session, held.capability, args[0]);
		}
		if (action === "removeRoom" && args.length === 1) {
			return () => removeOperatorRoom(held.session, held.capability, args[0]);
		}
		if (action === "releaseReference" && args.length === 1) {
			return () => releaseOperatorReference(held.session, held.capability, args[0]);
		}
		if (action === "clearTrouble" && args.length === 0) {
			return () => clearOperatorTrouble(held.session, held.capability);
		}
		if (action === "reset" && args.length === 1) {
			if (!["links", "registrations", "sessions", "rooms", "runtime", "all"].includes(args[0])) {
				throw new Error("Rooms operator reset has an invalid scope");
			}
			return () => resetOperatorScope(held.session, held.capability, args[0] as OperatorResetScope);
		}
		if (action === "giveModerator" && args.length === 1) {
			return async () => {
				await giveStewardship(held.session, held.capability, args[0]);
			};
		}
		if (action === "revokeModerator" && args.length === 1) {
			return async () => {
				await revokeStewardship(held.session, held.capability, args[0]);
			};
		}
		throw new Error(`Rooms operator action ${action} has invalid arguments`);
	}

	operatorRetireMatching(
		scope: string,
		category: OperatorCategory,
		query: string,
		limit: number,
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorRetireBatch> {
		const held = this.#operator(scope);
		return operatorRetireMatching(held.session, held.capability, category, query, limit, referenceKind);
	}

	operatorSnapshot(
		scope: string,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorSnapshot> {
		const held = this.#operator(scope);
		return snapshotOperator(held.session, held.capability, query, referenceKind);
	}

	operatorPage(
		scope: string,
		category: OperatorCategory,
		cursor: number,
		query = "",
		referenceKind: OperatorReferenceKind | null = null,
	): Promise<OperatorPage> {
		const held = this.#operator(scope);
		return operatorPage(held.session, held.capability, category, cursor, query, referenceKind);
	}

	async reconcile(
		checkpoint: RoomsSessionState,
		directories: ReadonlyMap<string, ConnectedDirectory>,
	): Promise<void> {
		const changedScopes = new Set<string>();
		const wanted = new Map(checkpoint.capabilities.operations.map((saved) => [
			`${saved.capability}\u0000${saved.scope}`,
			saved,
		]));
		for (const key of [...this.#issueKeys]) {
			if (!wanted.has(key)) this.#noteIssue(key, null);
		}
		for (const [key, held] of this.#held) {
			const saved = wanted.get(key);
			const directory = directories.get(held.directoryId);
			if (saved != null && saved.swiss === held.swiss && directory?.directory.session === held.session) continue;
			changedScopes.add(held.directoryId);
			this.#release(key, held);
		}
		const waiting = new Map<string, string[]>();
		const taking: Promise<void>[] = [];
		for (const saved of checkpoint.capabilities.operations) {
			if (saved.capability === "viz" || saved.capability === "peering") continue;
			const key = `${saved.capability}\u0000${saved.scope}`;
			if (this.#held.has(key)) continue;
			const directory = directories.get(saved.scope);
			if (directory == null) {
				if (this.#noteIssue(key, "the capability scope is not connected")) {
					const capabilities = waiting.get(saved.scope) ?? [];
					capabilities.push(saved.capability);
					waiting.set(saved.scope, capabilities);
				}
				continue;
			}
			taking.push(this.#take(key, saved, directory, changedScopes));
		}
		await Promise.all(taking);
		for (const [scope, capabilities] of waiting) {
			console.error(
				`rooms session: saved ${
					capabilities.join(", ")
				} capabilities are waiting for disconnected directory ${scope}`,
			);
		}
		for (const scope of changedScopes) this.#invalidated(scope);
	}

	releaseFor(directoryId: string): void {
		let changed = false;
		for (const [key, held] of this.#held) {
			if (held.directoryId !== directoryId) continue;
			changed = true;
			this.#release(key, held);
		}
		if (changed) this.#invalidated(directoryId);
	}

	close(): void {
		for (const [key, held] of this.#held) this.#release(key, held);
		for (const key of [...this.#issueKeys]) this.#noteIssue(key, null);
	}

	#operator(scope: string): HeldOperation {
		return this.#capability(scope, "operator");
	}

	async #take(
		key: string,
		saved: OperationCredential,
		directory: ConnectedDirectory,
		changedScopes: Set<string>,
	): Promise<void> {
		try {
			const capability = await directory.directory.session.fetch(saved.swiss);
			let stopWatch: (() => void) | null = null;
			try {
				if (saved.capability === "operator") {
					stopWatch = await subscribeOperator(
						directory.directory.session,
						capability,
						() => this.#invalidated(saved.scope),
					);
				}
			} catch (error) {
				settleCapabilityCleanup(
					"failed operator-watch capability release failed",
					() => directory.directory.session.release(capability),
				);
				throw error;
			}
			this.#held.set(key, {
				directoryId: saved.scope,
				swiss: saved.swiss,
				session: directory.directory.session,
				capability,
				stopWatch,
			});
			this.#noteIssue(key, null);
			changedScopes.add(saved.scope);
		} catch (error) {
			this.#noteIssue(key, error);
		}
	}

	#capability(scope: string, capability: string): HeldOperation {
		const held = this.#held.get(`${capability}\u0000${scope}`);
		if (held == null) throw new Error(`that ${capability} capability is not active in this session`);
		return held;
	}

	#release(key: string, held: HeldOperation): void {
		settleCapabilityCleanup(`operator watcher ${key} would not stop`, () => held.stopWatch?.());
		settleCapabilityCleanup(
			`operations capability ${key} would not release`,
			() => held.session.release(held.capability),
		);
		this.#held.delete(key);
	}

	#noteIssue(key: string, error: unknown | null): boolean {
		if (error == null) this.#issueKeys.delete(key);
		else this.#issueKeys.add(key);
		return this.#setIssue(`capability:${key}`, error);
	}
}
