import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
// Operations select separately retained fields. Reads use scoped Rust
// readers; writes run through the original command and its exact receipt.
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomsOperationsController } from "../../controller/session.ts";
import type { OpsCap } from "../../types.ts";
import type { OperatorReferenceKind, OperatorSnapshot } from "../../../../lib/operator.ts";
import { parseOperatorSnapshotJson } from "../../../../lib/operator_snapshot.ts";
import { appendOperatorPage, operatorStateOf } from "../../ops/operator_projection.ts";
import { type Coordinate, fieldKey, type WorkspaceIntent } from "./model.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { formatOpsBundle, parseOpsBundleDraft } from "../../ops/bundle.ts";
import type { RoomsManagedOperationsReader } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { operationHolding, operationKind, operationSelection } from "./operations_selection.ts";
import { OperationsAcquisitionRefused } from "./actions.ts";
import { OPS_CATALOG } from "../../ops/catalog.ts";

export function managedOperations(page: RoomsPageContext, session: ManagedRoomsSession): RoomsOperationsController {
	const projection = page.projection;
	const refreshes = new Map<OpsCap, number>();
	function holding(cap: OpsCap): { coordinate: Coordinate; kind?: string } | null {
		return operationHolding(session.current?.intent, cap);
	}
	function selected(cap: OpsCap): { coordinate: Coordinate; kind?: string } {
		const row = holding(cap);
		if (row == null) throw new Error(`This workspace holds no ${cap} capability`);
		return row;
	}
	const outcome = async (work: () => Promise<unknown>): Promise<string> => {
		try {
			await work();
			return "";
		} catch (error) {
			return refusalText(error);
		}
	};
	async function read<T>(
		cap: OpsCap,
		work: (reader: RoomsManagedOperationsReader) => Promise<T>,
		row = selected(cap),
	): Promise<T> {
		const reader: RoomsManagedOperationsReader = await session.workspace.operationsReader(
			JSON.stringify(row.coordinate),
			row.kind,
		);
		try {
			return await work(reader);
		} finally {
			reader.free();
		}
	}
	async function refresh(cap: OpsCap, query = "", kind: OperatorReferenceKind | null = null): Promise<void> {
		const row = selected(cap);
		const selection = operationSelection(session.current?.intent, cap);
		const request = (refreshes.get(cap) ?? 0) + 1;
		refreshes.set(cap, request);
		const current = () =>
			refreshes.get(cap) === request &&
			operationSelection(session.current?.intent, cap) === selection;
		if (cap === "trace") {
			const snapshot = await session.workspace.traceSnapshot(JSON.stringify(row.coordinate));
			if (current()) store.setTracePublish(projection, snapshot);
			return;
		}
		if (cap === "peering") {
			const publications = await session.workspace.peeringSnapshot();
			if (current()) store.setPeering(projection, { publications });
			return;
		}
		if (cap === "operator") {
			const snapshot: OperatorSnapshot = parseOperatorSnapshotJson(
				JSON.stringify(await read(cap, (reader) => reader.operatorSnapshot(query, kind), row)),
			);
			if (current()) store.setRoomsOperator(projection, operatorStateOf(snapshot, query, kind));
			return;
		}
		const snapshot = await read(cap, (reader) => reader.snapshot(), row);
		if (!current()) return;
		if (cap === "listeners") store.setListeners(projection, snapshot);
		else if (cap === "diagnostics") store.setDiagnostics(projection, snapshot);
		else if (cap === "irc") store.setIrcGateway(projection, snapshot);
	}
	async function operation(cap: OpsCap, action: string, args: string[] = []): Promise<unknown> {
		const row = selected(cap);
		const result = await session.actions.run(cap === "operator" ? "operator" : "operations", [
			cap === "operator" ? JSON.stringify(row.coordinate.key) : JSON.stringify(row.coordinate),
			...(row.kind == null ? [] : [row.kind]),
			action,
			...args,
		]);
		await refresh(cap);
		return result;
	}
	const operator = (action: string, args: string[] = []) => outcome(() => operation("operator", action, args));
	async function connection(id: string, action: string, args: string[] = []): Promise<void> {
		// A gateway connection ID is comparison data, never a custody key.
		// Acquire this exact connection for the gesture and retire its selection
		// after completion. An uncertain command retains its source for recovery.
		const gateway = selected("irc");
		await session.refresh();
		let row = session.current?.intent.operations?.find((row) =>
			row.kind === "ircConnection" && row.connection?.id === id &&
			row.connection.gateway.role === gateway.coordinate.role &&
			row.connection.gateway.key === gateway.coordinate.key
		);
		if (row == null) {
			const command = await session.command("operations", [
				JSON.stringify(gateway.coordinate),
				"ircGateway",
				"connection",
				id,
			]);
			await session.completeResult(command);
			row = session.current?.intent.operations?.find((row) => row.connection?.operation === command.id);
		}
		if (row == null) throw new Error("The acquired connection is no longer selected");
		await session.actions.run("operations", [JSON.stringify(row.handle), "ircConnection", action, ...args]);
		const retired = await session.candidate();
		retired.intent.operations = retired.intent.operations?.filter((entry) =>
			entry.handle.key !== row.handle.key || entry.handle.role !== row.handle.role
		);
		await session.actions.replace(retired);
		await refresh("irc");
	}
	async function readBundle(intent = session.current?.intent): Promise<string> {
		const entries = new Map<OpsCap, string>();
		for (const cap of ["operator", "listeners", "diagnostics", "irc", "trace", "peering"] as const) {
			const row = operationHolding(intent, cap);
			if (row != null) {
				const uri: string | null = await session.workspace.custodyRecipe(JSON.stringify(row.coordinate));
				if (uri == null) throw new Error(`The held ${cap} capability has no durable recipe`);
				entries.set(cap, uri);
			}
		}
		return formatOpsBundle(entries);
	}
	return {
		watchOpsBundle: (changed) => {
			let previous = JSON.stringify([session.current?.intent.operators, session.current?.intent.operations]);
			return session.subscribe(() => {
				const next = JSON.stringify([session.current?.intent.operators, session.current?.intent.operations]);
				if (previous !== next) {
					previous = next;
					void Promise.resolve(changed()).catch((error) =>
						store.noteTrouble(projection, managedText.operationsInventory, refusalText(error))
					);
				}
			});
		},
		readOpsBundle: readBundle,
		replaceOpsBundle: async (raw) => {
			const snapshot = await session.candidate();
			const previous = await readBundle(snapshot.intent);
			try {
				const entries = parseOpsBundleDraft(raw);
				const original = {
					operators: snapshot.intent.operators,
					operations: (snapshot.intent.operations ?? []).filter((row) => row.connection == null),
				};
				const replacement: Pick<WorkspaceIntent, "operators" | "operations"> = {
					operators: [],
					operations: [],
				};
				const previousEntries = parseOpsBundleDraft(previous);
				const imports: { coordinate: Coordinate; uri: string }[] = [];
				for (const [cap, uri] of entries) {
					const unchanged = previousEntries.get(cap) === uri ? operationHolding(snapshot.intent, cap) : null;
					const coordinate: Coordinate = unchanged?.coordinate ?? {
						role: cap === "operator" ? "operator" : "operations",
						key: fieldKey(),
					};
					if (cap === "operator") replacement.operators.push(coordinate.key);
					else replacement.operations!.push({ kind: operationKind(cap), handle: coordinate });
					if (unchanged == null) imports.push({ coordinate, uri });
				}
				await session.actions.operations(original, replacement, imports);
				return { bundle: raw, failures: [] };
			} catch (error) {
				if (error instanceof OperationsAcquisitionRefused) {
					const failures = error.failures.map(({ capability, reason, advice }) => ({
						capability,
						reason: advice == null ? refusalText(new Error(reason)) : `${advice} (${reason})`,
					}));
					// The draft may be repaired or discarded. Its exact refusal
					// remains in the existing bounded browser journal for inspection.
					for (const failure of failures) {
						store.noteTrouble(projection, OPS_CATALOG[failure.capability].label, failure.reason);
					}
					return {
						bundle: previous,
						failures,
					};
				}
				return { bundle: previous, failures: [{ capability: null, reason: refusalText(error) }] };
			}
		},
		refreshOpsCap: (cap) => refresh(cap),
		openBridgeConnection: (answers) => outcome(() => operation("irc", "openConnection", [JSON.stringify(answers)])),
		closeBridgeConnection: (id) => outcome(() => connection(id, "closeConnection")),
		addBridgeLease: (id, answers) => outcome(() => connection(id, "addLease", [JSON.stringify(answers)])),
		removeBridgeLease: (id, lease) => outcome(() => connection(id, "removeLease", [lease])),
		listenerUp: (transport, options) =>
			outcome(() => operation("listeners", "up", [transport, JSON.stringify(options ?? {})])),
		listenerDown: (id) => outcome(() => operation("listeners", "down", [String(id)])),
		giveRoomStewardship: (name) =>
			outcome(async () => {
				const source = selected("operator");
				const command = await session.command("operator", [
					JSON.stringify(source.coordinate.key),
					"giveModerator",
					name,
				]);
				await session.completeResult(command);
				await refresh("operator");
			}),
		revokeRoomStewardship: (name) => operator("revokeModerator", [name]),
		revokeRoomLink: (name) => operator("revokeRoomLink", [name]),
		revokeRoomAuthority: (kind, token) => operator("revokeRoomAuthority", [kind, token]),
		revokeNick: (nick, id) => operator("revokeNick", [nick, id]),
		disconnectSession: (id) => operator("disconnectSession", [id]),
		removeOperatorRoom: (id) => operator("removeRoom", [id]),
		releaseOperatorReference: (id) => operator("releaseReference", [id]),
		clearOperatorTrouble: () => operator("clearTrouble"),
		resetOperatorScope: (scope) => operator("reset", [scope]),
		searchOperator: (query, kind) => outcome(() => refresh("operator", query, kind)),
		loadMoreOperator: (category) =>
			outcome(async () => {
				const current = projection.get().operator;
				if (current == null || current.next[category] == null) return;
				const selection = operationSelection(session.current?.intent, "operator");
				const page = await read("operator", (reader) =>
					reader.operatorPage(
						category,
						String(current.next[category]),
						current.search,
						current.referenceKind,
					));
				if (
					projection.get().operator === current &&
					operationSelection(session.current?.intent, "operator") === selection
				) store.setRoomsOperator(projection, appendOperatorPage(current, { ...page, category }));
			}),
		retireMatchingOperator: async (category, query, limit, kind) => {
			try {
				return await operation("operator", "retireMatching", [
					category,
					query,
					String(limit),
					...(kind == null ? [] : [kind]),
				]) as { retired: number; remaining: number; refused: string };
			} catch (error) {
				return refusalText(error);
			}
		},
		recoverRoomManager: (key) =>
			outcome(async () => {
				const row = store.getConv(projection, key);
				if (row?.type !== "room") throw new Error("This room is no longer held");
				const held = session.current?.intent.conversations.find((room) => room.id === row.persistId);
				if (held?.kind !== "room" || held.access == null) {
					throw new Error("Recovery requires the exact held room access");
				}
				const identity: string = await session.workspace.roomManagementIdentity(
					JSON.stringify({ role: "roomAccess", key: held.access }),
				);
				const source = selected("operator");
				const command = await session.command("operator", [
					JSON.stringify(source.coordinate.key),
					"giveManager",
					identity,
				]);
				await session.completeResult(command);
			}),
		resumeSessionEffect: (id) => outcome(() => session.completeOperation(id)),
		publishPeeredRoom: (key, name) =>
			outcome(async () => {
				const room = store.getConv(projection, key);
				if (room?.type !== "room") throw new Error("This room is no longer held");
				const selected = session.current?.intent.conversations.find((row) => row.id === room.persistId);
				if (selected?.kind !== "room" || selected.access == null) {
					throw new Error("No room publication authority is held");
				}
				const publisher = holding("peering");
				if (publisher == null) throw new Error("This workspace holds no peering capability");
				const command = await session.command("publishPeeredRoom", [
					room.dir,
					name,
					JSON.stringify(selected.access),
					JSON.stringify(publisher.coordinate),
				]);
				await session.completeResult(command);
				await refresh("peering");
			}),
		revokePeeredPublication: (id) =>
			outcome(async () => {
				const row = session.current?.intent.peering.find((row) => row.id === String(id));
				if (row == null) throw new Error("The original publication lease is no longer held");
				await session.actions.run("revokePeeredRoom", [row.id, JSON.stringify(row.lease)]);
				await refresh("peering");
			}),
	};
}
