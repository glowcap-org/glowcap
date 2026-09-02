// Operations authority projected through one attached Rooms session.

import * as store from "../store.ts";
import { appendOperatorPage, operatorStateOf } from "../net/operator.ts";
import { opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import * as prefs from "../prefs.ts";
import type { OpsCap } from "../types.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { attachedOperationsBundle, attachedOperationsCredentials } from "./operations_bundle.ts";
import { OperatorRefreshQueue } from "../ops/operator_refresh.ts";
import type { PageProjection } from "../store/core.ts";
import type { RoomsSessionIssue } from "../../../lib/session/client.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { OperatorReferenceKind } from "../../../lib/operator.ts";
type OperatorFilter = { search: string; referenceKind: OperatorReferenceKind | null };

export type AttachedOperationsActions = Pick<
	RoomsSessionController,
	| "openBridgeConnection"
	| "closeBridgeConnection"
	| "addBridgeLease"
	| "removeBridgeLease"
	| "revokeRoomLink"
	| "revokeRoomAuthority"
	| "revokeNick"
	| "disconnectSession"
	| "removeOperatorRoom"
	| "releaseOperatorReference"
	| "clearOperatorTrouble"
	| "resetOperatorScope"
	| "giveRoomStewardship"
	| "revokeRoomStewardship"
	| "loadMoreOperator"
	| "searchOperator"
	| "retireMatchingOperator"
	| "listenerUp"
	| "listenerDown"
	| "publishPeeredRoom"
	| "revokePeeredPublication"
	| "refreshOpsCap"
	| "readOpsBundle"
	| "replaceOpsBundle"
>;

export interface AttachedOperations {
	readonly actions: AttachedOperationsActions;
	refreshOperator(): Promise<void>;
}

type OperationCredentials = RoomsSessionState["capabilities"]["operations"];

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

async function actionResult(action: () => Promise<void>): Promise<string> {
	try {
		await action();
		return "";
	} catch (error) {
		return errorText(error);
	}
}

function sameCredentials(left: OperationCredentials, right: OperationCredentials): boolean {
	if (left === right) return true;
	if (left.length !== right.length) return false;
	for (let index = 0; index < left.length; index += 1) {
		const entry = left[index];
		const other = right[index];
		if (
			entry == null || other == null || entry.capability !== other.capability || entry.scope !== other.scope ||
			entry.swiss !== other.swiss
		) return false;
	}
	return true;
}

function sameStrings(left: readonly string[], right: readonly string[]): boolean {
	if (left === right) return true;
	if (left.length !== right.length) return false;
	for (let index = 0; index < left.length; index += 1) if (left[index] !== right[index]) return false;
	return true;
}

function operationsIssue(issue: RoomsSessionIssue): boolean {
	return issue.subject === "session" || issue.subject.startsWith("capability:") ||
		issue.subject.startsWith("peering:");
}

/** Compare the bounded relevant subsequences without allocating filtered rows
 * on every draft or selection snapshot. */
function sameOperationsIssues(left: readonly RoomsSessionIssue[], right: readonly RoomsSessionIssue[]): boolean {
	let leftAt = 0;
	let rightAt = 0;
	while (true) {
		while (leftAt < left.length && !operationsIssue(left[leftAt])) leftAt += 1;
		while (rightAt < right.length && !operationsIssue(right[rightAt])) rightAt += 1;
		const leftIssue = left[leftAt];
		const rightIssue = right[rightAt];
		if (leftIssue == null || rightIssue == null) return leftIssue == null && rightIssue == null;
		if (leftIssue.subject !== rightIssue.subject || leftIssue.reason !== rightIssue.reason) return false;
		leftAt += 1;
		rightAt += 1;
	}
}

function capabilityFromIssue(issue: RoomsSessionIssue): OpsCap | null {
	if (!issue.subject.startsWith("capability:")) return null;
	const capability = issue.subject.slice("capability:".length).split("\0", 1)[0];
	return capability === "listeners" || capability === "diagnostics" || capability === "irc" ||
			capability === "operator" || capability === "peering" || capability === "viz"
		? capability
		: null;
}

export function attachedOperations(
	projection: PageProjection,
	controller: AttachedRoomsController,
): AttachedOperations {
	const homeScope = () => controller.current?.checkpoint.directories.find((directory) => directory.home)?.id ?? null;
	const savedCapability = (capability: OpsCap, scope: string): boolean =>
		controller.current?.checkpoint.capabilities.operations.some((entry) =>
			entry.capability === capability && entry.scope === scope
		) === true;
	const operator = async (action: string, args: string[] = []): Promise<string> => {
		const scope = homeScope();
		if (scope == null) return "This shared session has no home directory for its operator capability.";
		return await actionResult(async () => {
			await controller.operator(scope, action, args);
			await refreshOperator();
		});
	};
	async function readOperator(filter: OperatorFilter | undefined, currentRequest: () => boolean): Promise<void> {
		const scope = homeScope();
		if (scope == null || !savedCapability("operator", scope)) {
			store.setRoomsOperator(projection, null);
			return;
		}
		const current = projection.get().operator;
		const asked = filter?.search ?? current?.search ?? "";
		const referenceKind = filter != null ? filter.referenceKind : current?.referenceKind ?? null;
		try {
			const snapshot = await controller.operatorSnapshot(scope, asked, referenceKind);
			if (currentRequest()) store.setRoomsOperator(projection, operatorStateOf(snapshot, asked, referenceKind));
		} catch (error) {
			if (!currentRequest()) return;
			store.setRoomsOperator(projection, null);
			store.noteTrouble(projection, "shared session operator", errorText(error));
		}
	}
	const refreshQueue = new OperatorRefreshQueue(readOperator);
	const refreshOperator = (search?: string, referenceKind: OperatorReferenceKind | null = null): Promise<void> => {
		return refreshQueue.request(search == null ? undefined : { search, referenceKind });
	};
	const refreshCapability = async (
		capability: "listeners" | "diagnostics" | "irc",
	): Promise<void> => {
		const scope = homeScope();
		const clear = () => {
			if (capability === "listeners") store.setListeners(projection, null);
			else if (capability === "diagnostics") store.setDiagnostics(projection, null);
			else store.setIrcGateway(projection, null);
		};
		if (scope == null || !savedCapability(capability, scope)) {
			clear();
			return;
		}
		try {
			const snapshot = await controller.operationsSnapshot(scope, capability);
			if (snapshot.capability === "listeners") store.setListeners(projection, snapshot.rows);
			else if (snapshot.capability === "diagnostics") store.setDiagnostics(projection, snapshot.rows);
			else if (snapshot.capability === "irc") store.setIrcGateway(projection, snapshot.gateway);
		} catch (error) {
			clear();
			store.noteTrouble(projection, `shared session ${capability}`, errorText(error));
		}
	};
	const refreshViz = async (): Promise<void> => {
		const credential = controller.current?.checkpoint.capabilities.operations.find((entry) =>
			entry.capability === "viz"
		);
		if (credential == null) {
			store.setVizPublish(projection, null);
			return;
		}
		try {
			const snapshot = await controller.operationsSnapshot(credential.scope, "viz");
			if (snapshot.capability === "viz") {
				store.setVizPublish(projection, {
					url: snapshot.url,
					connected: snapshot.connected,
					refusal: snapshot.refusal,
				});
			}
		} catch (error) {
			store.setVizPublish(projection, null);
			store.noteTrouble(projection, "shared session visualizer", errorText(error));
		}
	};
	const refreshPeering = async (): Promise<void> => {
		const credential = controller.current?.checkpoint.capabilities.operations.find((entry) =>
			entry.capability === "peering"
		);
		if (credential == null) {
			store.setPeering(projection, null);
			return;
		}
		try {
			const snapshot = await controller.operationsSnapshot(credential.scope, "peering");
			if (snapshot.capability === "peering") store.setPeering(projection, { publications: snapshot.rows });
		} catch (error) {
			store.setPeering(projection, {
				publications: (controller.current?.checkpoint.peering ?? [])
					.filter((intent) => intent.destination === credential.scope)
					.map((intent) => ({
						id: intent.id,
						name: intent.name,
						source: intent.source,
						phase: "failed" as const,
					})),
			});
			store.noteTrouble(projection, "shared session peering", errorText(error));
		}
	};
	const refreshAll = async (): Promise<void> => {
		await Promise.all([
			refreshCapability("listeners"),
			refreshCapability("diagnostics"),
			refreshCapability("irc"),
			refreshOperator(),
			refreshViz(),
			refreshPeering(),
		]);
	};

	controller.onOperationsInvalidated((scope) => {
		if (scope === homeScope()) void refreshAll();
		else if (
			controller.current?.checkpoint.capabilities.operations.some((entry) =>
				(entry.capability === "viz" || entry.capability === "peering") && entry.scope === scope
			) === true
		) {
			void refreshViz();
			void refreshPeering();
		}
	});
	let priorCredentials: OperationCredentials | null = null;
	let priorConnected: readonly string[] = [];
	let priorIssues: readonly RoomsSessionIssue[] = [];
	controller.onSnapshot((snapshot) => {
		const credentials = snapshot.checkpoint.capabilities.operations;
		const changed = priorCredentials == null || !sameCredentials(priorCredentials, credentials) ||
			!sameStrings(priorConnected, snapshot.connectedDirectories) ||
			!sameOperationsIssues(priorIssues, snapshot.issues);
		priorCredentials = credentials;
		priorConnected = snapshot.connectedDirectories;
		priorIssues = snapshot.issues;
		if (changed) void refreshAll();
	});
	const readBundle = (): string => {
		const checkpoint = controller.current?.checkpoint;
		return checkpoint == null ? "" : attachedOperationsBundle(checkpoint);
	};

	return {
		refreshOperator,
		actions: {
			openBridgeConnection: async (answers) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for bridge administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "irc", "openConnection", [JSON.stringify(answers)]);
					await refreshCapability("irc");
				});
			},
			closeBridgeConnection: async (connectionId) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for bridge administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "irc", "closeConnection", [connectionId]);
					await refreshCapability("irc");
				});
			},
			addBridgeLease: async (connectionId, answers) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for bridge administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "irc", "addLease", [connectionId, JSON.stringify(answers)]);
					await refreshCapability("irc");
				});
			},
			removeBridgeLease: async (connectionId, leaseId) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for bridge administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "irc", "removeLease", [connectionId, leaseId]);
					await refreshCapability("irc");
				});
			},
			revokeRoomLink: (name) => operator("revokeRoomLink", [name]),
			revokeRoomAuthority: (kind, token) => operator("revokeRoomAuthority", [kind, token]),
			revokeNick: (nick, sessionId) => operator("revokeNick", [nick, sessionId]),
			disconnectSession: (id) => operator("disconnectSession", [id]),
			removeOperatorRoom: (id) => operator("removeRoom", [id]),
			releaseOperatorReference: (id) => operator("releaseReference", [id]),
			clearOperatorTrouble: () => operator("clearTrouble"),
			resetOperatorScope: (scope) => operator("reset", [scope]),
			giveRoomStewardship: (name) => operator("giveModerator", [name]),
			revokeRoomStewardship: (name) => operator("revokeModerator", [name]),
			searchOperator: async (query, referenceKind) => {
				const scope = homeScope();
				if (scope == null) return "This shared session does not hold the Rooms operator capability.";
				try {
					await refreshOperator(query, referenceKind);
					return "";
				} catch (error) {
					return errorText(error);
				}
			},
			retireMatchingOperator: async (category, query, limit, referenceKind) => {
				const scope = homeScope();
				if (scope == null) return "This shared session does not hold the Rooms operator capability.";
				try {
					// One read when the sweep settles, not one between batches.
					return await controller.operatorRetireMatching(scope, category, query, limit, referenceKind);
				} catch (error) {
					return errorText(error);
				}
			},
			loadMoreOperator: async (category) => {
				const scope = homeScope();
				const current = projection.get().operator;
				if (scope == null || current == null) {
					return "This shared session does not hold the Rooms operator capability.";
				}
				const cursor = current.next[category];
				if (cursor == null) return "";
				try {
					const page = await controller.operatorPage(
						scope,
						category,
						cursor,
						current.search,
						current.referenceKind,
					);
					const latest = projection.get().operator;
					if (latest == null || latest.next[category] !== cursor) return "";
					if (page.revision !== latest.revision) {
						await refreshOperator();
						return "";
					}
					store.setRoomsOperator(projection, appendOperatorPage(latest, page));
					return "";
				} catch (error) {
					return errorText(error);
				}
			},
			listenerUp: async (transport, options) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for listener administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "listeners", "up", [transport, JSON.stringify(options ?? {})]);
					await refreshCapability("listeners");
				});
			},
			listenerDown: async (id) => {
				const scope = homeScope();
				if (scope == null) return "This shared session has no home directory for listener administration.";
				return await actionResult(async () => {
					await controller.operations(scope, "listeners", "down", [String(id)]);
					await refreshCapability("listeners");
				});
			},
			publishPeeredRoom: async (key, name) => {
				const checkpoint = controller.current?.checkpoint;
				const room = store.getConv(projection, key);
				const destination = checkpoint?.capabilities.operations.find((entry) => entry.capability === "peering")
					?.scope;
				if (checkpoint == null) return "The shared session state is not available.";
				if (room?.type !== "room") return "That room is no longer available.";
				if (destination == null) return "Save a directory peering capability before publishing this room.";
				return await actionResult(async () => {
					await controller.publishPeeredRoom({
						id: crypto.randomUUID(),
						destination,
						source: room.persistId,
						name,
					});
					await refreshPeering();
				});
			},
			revokePeeredPublication: (id) =>
				actionResult(async () => {
					await controller.revokePeeredRoom(String(id));
					await refreshPeering();
				}),
			refreshOpsCap: async (capability) => {
				if (capability === "operator") await refreshOperator();
				else if (capability === "listeners" || capability === "diagnostics" || capability === "irc") {
					await refreshCapability(capability);
				} else if (capability === "viz") await refreshViz();
				else if (capability === "peering") await refreshPeering();
			},
			readOpsBundle: () => Promise.resolve(readBundle()),
			replaceOpsBundle: async (raw) => {
				try {
					const draft = parseOpsBundleDraft(raw);
					if (draft.size > 0 && !opsBundleReady(draft)) throw new Error("Supply every enabled swiss number.");
					const checkpoint = controller.current?.checkpoint;
					if (checkpoint == null) throw new Error("The shared session is not available.");
					const credentials = await attachedOperationsCredentials(checkpoint, draft, prefs.advertisedViz);
					await controller.replaceOperationsCapabilities(credentials);
					const settled = await controller.refreshSnapshot();
					await refreshAll();
					const failures = settled.issues.flatMap((issue) => {
						const capability = capabilityFromIssue(issue);
						return capability == null ? [] : [{ capability, reason: issue.reason }];
					});
					return { bundle: readBundle(), failures };
				} catch (error) {
					return {
						bundle: readBundle(),
						failures: [{
							capability: null,
							reason: errorText(error),
						}],
					};
				}
			},
		},
	};
}
