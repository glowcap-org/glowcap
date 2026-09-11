// Operations authority projected through one attached Rooms session.

import * as store from "../store.ts";
import { operatorStateOf } from "../ops/operator_projection.ts";
import { opsBundleReady, parseOpsBundleDraft } from "../ops/bundle.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import * as prefs from "../prefs.ts";
import type { OpsCap } from "../types.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { attachedOperationsBundle, attachedOperationsView } from "./operations_bundle.ts";
import type { PageProjection } from "../store/core.ts";
import type { RoomsSessionIssue } from "../../../lib/session/client.ts";
import type { OperatorReferenceKind } from "../../../lib/operator.ts";
import type { RoomsPageContext } from "../page.ts";
import { persistCurrentWorkspace } from "../workspace_state.ts";

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

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** Read failures already owned by durable capability or directory state. They
 * must not also become browser-trouble entries; everything else retains the
 * generic journal as its last-resort surface. */
function ownedReadFailure(reason: string): boolean {
	return reason.includes("unknown swissnum") ||
		reason.includes("capability directory is not connected") ||
		(reason.startsWith("this Rooms session has no ") && reason.includes(" capability for scope "));
}

async function actionResult(action: () => Promise<void>): Promise<string> {
	try {
		await action();
		return "";
	} catch (error) {
		return errorText(error);
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
	page: RoomsPageContext,
	projection: PageProjection,
	controller: AttachedRoomsController,
): AttachedOperations {
	const operator = async (action: string, args: string[] = []): Promise<string> => {
		return await actionResult(async () => {
			await controller.runOperation("operator", action, args);
			await refreshOperator();
		});
	};
	const clearCapability = (capability: OpsCap): void => {
		if (capability === "operator") store.setRoomsOperator(projection, null);
		else if (capability === "listeners") store.setListeners(projection, null);
		else if (capability === "diagnostics") store.setDiagnostics(projection, null);
		else if (capability === "irc") store.setIrcGateway(projection, null);
		else if (capability === "viz") store.setVizPublish(projection, null);
		else store.setPeering(projection, null);
	};
	controller.onOperationsRead((result) => {
		const snapshot = result.snapshot;
		if (result.capability === "operator") {
			if (snapshot == null) clearCapability("operator");
			else {
				store.setRoomsOperator(
					projection,
					operatorStateOf(
						snapshot as import("../../../lib/operator.ts").OperatorSnapshot,
						result.search,
						result.referenceKind,
					),
				);
			}
		} else if (snapshot == null) {
			clearCapability(result.capability);
		} else if ("capability" in snapshot) {
			if (snapshot.capability === "listeners") store.setListeners(projection, snapshot.rows);
			else if (snapshot.capability === "diagnostics") store.setDiagnostics(projection, snapshot.rows);
			else if (snapshot.capability === "irc") store.setIrcGateway(projection, snapshot.gateway);
			else if (snapshot.capability === "viz") {
				store.setVizPublish(projection, {
					url: snapshot.url,
					connected: snapshot.connected,
					refusal: snapshot.refusal,
				});
			} else if (snapshot.capability === "peering") store.setPeering(projection, { publications: snapshot.rows });
		}
		if (result.error != null && !ownedReadFailure(result.error)) {
			store.noteTrouble(projection, `session ${result.capability}`, result.error);
		}
	});
	const refresh = (capability: OpsCap, search?: string, kind?: OperatorReferenceKind | null): Promise<void> =>
		controller.refreshOperations(capability, search, kind);
	const refreshOperator = (search?: string, referenceKind: OperatorReferenceKind | null = null): Promise<void> =>
		refresh("operator", search, referenceKind);
	const refreshCapability = (capability: "listeners" | "diagnostics" | "irc") => refresh(capability);
	const refreshViz = () => refresh("viz");
	const refreshPeering = () => refresh("peering");
	const refreshAll = async (wanted: ReadonlySet<OpsCap>, unavailable: ReadonlySet<OpsCap>): Promise<void> => {
		const attempts: readonly [OpsCap, () => Promise<void>][] = [
			["listeners", () => refreshCapability("listeners")],
			["diagnostics", () => refreshCapability("diagnostics")],
			["irc", () => refreshCapability("irc")],
			["operator", () => refreshOperator()],
			["viz", refreshViz],
			["peering", refreshPeering],
		];
		for (const [capability] of attempts) if (!wanted.has(capability)) clearCapability(capability);
		const active = attempts.filter(([capability]) => wanted.has(capability));
		const outcomes = await Promise.allSettled(active.map(([, attempt]) => attempt()));
		for (const [index, outcome] of outcomes.entries()) {
			const capability = active[index][0];
			const reason = outcome.status === "rejected" ? errorText(outcome.reason) : "";
			if (outcome.status === "rejected" && !unavailable.has(capability) && !ownedReadFailure(reason)) {
				store.noteTrouble(projection, `session ${capability}`, reason);
			}
		}
	};
	const readBundle = (): string => {
		const checkpoint = controller.current?.checkpoint;
		return checkpoint == null ? "" : attachedOperationsBundle(checkpoint);
	};

	return {
		refreshOperator,
		actions: {
			openBridgeConnection: async (answers) => {
				return await actionResult(async () => {
					await controller.runOperation("irc", "openConnection", [JSON.stringify(answers)]);
					await refreshCapability("irc");
				});
			},
			closeBridgeConnection: async (connectionId) => {
				return await actionResult(async () => {
					await controller.runOperation("irc", "closeConnection", [connectionId]);
					await refreshCapability("irc");
				});
			},
			addBridgeLease: async (connectionId, answers) => {
				return await actionResult(async () => {
					await controller.runOperation("irc", "addLease", [connectionId, JSON.stringify(answers)]);
					await refreshCapability("irc");
				});
			},
			removeBridgeLease: async (connectionId, leaseId) => {
				return await actionResult(async () => {
					await controller.runOperation("irc", "removeLease", [connectionId, leaseId]);
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
				try {
					await refreshOperator(query, referenceKind);
					return "";
				} catch (error) {
					return errorText(error);
				}
			},
			retireMatchingOperator: async (category, query, limit, referenceKind) => {
				try {
					// One read when the sweep settles, not one between batches.
					return await controller.retireOperatorMatches(category, query, limit, referenceKind);
				} catch (error) {
					return errorText(error);
				}
			},
			loadMoreOperator: (category) => actionResult(() => controller.loadOperatorPage(category)),
			listenerUp: async (transport, options) => {
				return await actionResult(async () => {
					await controller.runOperation("listeners", "up", [transport, JSON.stringify(options ?? {})]);
					await refreshCapability("listeners");
				});
			},
			listenerDown: async (id) => {
				return await actionResult(async () => {
					await controller.runOperation("listeners", "down", [String(id)]);
					await refreshCapability("listeners");
				});
			},
			publishPeeredRoom: async (key, name) => {
				const room = store.getConv(projection, key);
				if (room?.type !== "room") return "That room is no longer available.";
				return await actionResult(async () => {
					await controller.runOperation("peering", "publish", [room.persistId, name]);
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
					const { context } = attachedOperationsView(checkpoint);
					const advertised = draft.has("viz") ? await prefs.advertisedViz() ?? "" : "";
					await controller.replaceOperationsBundle(raw, advertised, context);
					const settled = await controller.refreshSnapshot();
					if (!persistCurrentWorkspace(page)) {
						throw new Error(
							"The capability set changed, but this browser refused to save it. Retry Save before reloading.",
						);
					}
					const failures = settled.issues.flatMap((issue) => {
						const capability = capabilityFromIssue(issue);
						return capability == null ? [] : [{ capability, reason: issue.reason }];
					});
					await refreshAll(new Set(draft.keys()), new Set(failures.map(({ capability }) => capability)));
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
