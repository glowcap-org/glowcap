// OCapN facets and revision observers for one durable Rooms session.

import {
	type Argument,
	type Behavior,
	currentSession,
	Ref,
	retainSecondaryFailure,
	type Session,
} from "@pancake/runtime";
import {
	ROOMS_SESSION_ADOPT_WORKSPACE,
	ROOMS_SESSION_CHANGED,
	ROOMS_SESSION_COMMAND,
	ROOMS_SESSION_FACET,
	ROOMS_SESSION_HISTORY,
	ROOMS_SESSION_ISSUE_GRANT,
	ROOMS_SESSION_OPERATIONS_CHANGED,
	ROOMS_SESSION_OPERATIONS_SNAPSHOT,
	ROOMS_SESSION_OPERATOR_PAGE,
	ROOMS_SESSION_OPERATOR_RETIRE,
	ROOMS_SESSION_OPERATOR_SNAPSHOT,
	ROOMS_SESSION_REPLACE,
	ROOMS_SESSION_RESOLVE_EFFECT,
	ROOMS_SESSION_RESUME_EFFECT,
	ROOMS_SESSION_REVOKE,
	ROOMS_SESSION_REVOKE_GRANT,
	ROOMS_SESSION_SNAPSHOT,
	ROOMS_SESSION_TYPING,
	ROOMS_SESSION_WATCH,
	type RoomsSessionFacet,
	type RoomsSessionRoomView,
} from "../lib/rooms_session.ts";
import { archiveRecordRow } from "../lib/archive.ts";
import { redactRoomsSessionCapabilities, type RoomsSessionState } from "../lib/rooms_state.ts";
import { OPERATOR_CATEGORIES, operatorPageAnswer, operatorRetireAnswer } from "../lib/operator.ts";
import { MAX_OPERATOR_QUERY, MAX_OPERATOR_RETIRE_BATCH } from "../lib/limits.ts";
import { DurableRoomsSessionState } from "./state.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import { describeRoomsSessionResult } from "./commands.ts";
import { resumeResultEffect } from "./result_effect.ts";
import { dispatchRoomsSessionCommand } from "./command_dispatch.ts";
import { validateOperationId } from "./effects.ts";
import { ARCHIVE_SHARE_UNHANDLED, dispatchArchiveShareCommand } from "./archive_share_commands.ts";
import { encodeSessionAccess, encodeSessionSnapshot } from "./snapshot_wire.ts";
import { ARCHIVED_FILE_UNHANDLED, dispatchArchivedFileCommand } from "./archive_file_commands.ts";
import { ATTACHMENT_COMMAND_UNHANDLED, dispatchAttachmentCommand } from "./attachment_commands.ts";
import { cleanupSettledBySessionClose } from "../lib/capability_cleanup.ts";
import type { RoomsSessionGrantAuthority } from "./grants.ts";
import { parseRoomsCheckpointRequest } from "./checkpoint_request.ts";
import { AttachedViewDelivery } from "./attached_view_delivery.ts";
import { admitSessionFacetArguments, takeSessionObserver } from "./facet_arguments.ts";
import { refuseCapabilityArguments } from "../lib/argument_custody.ts";
import { spawnFacetPair } from "./facet_pair.ts";
import { RoomInvitationAdmission } from "./invitation_admission.ts";

export {
	assertSessionCommandEnvelope,
	MAX_SESSION_COMMAND_ARGUMENTS,
	MAX_SESSION_COMMAND_BYTES,
} from "./command_dispatch.ts";

const MAX_ATTACHED_VIEWS = 64;
interface Observer {
	observer: Ref;
	stopClose: () => void;
	active: () => boolean;
	grant: symbol;
	rights: RoomsSessionFacet;
	delivery: AttachedViewDelivery;
}

function checkpointVisibleTo(rights: RoomsSessionFacet, checkpoint: RoomsSessionState): RoomsSessionState {
	return rights === "admin" ? checkpoint : redactRoomsSessionCapabilities(checkpoint);
}

function roomViewsVisibleTo(
	rights: RoomsSessionFacet,
	views: readonly RoomsSessionRoomView[],
): RoomsSessionRoomView[] {
	return rights === "observe"
		? views.map((view) => ({ ...view, canSetTopic: false, canModerate: false }))
		: [...views];
}

function refuseOwnedObserver(session: Session, observer: Ref, refusal: unknown): never {
	try {
		session.release(observer);
	} catch (cleanup) {
		if (cleanupSettledBySessionClose(cleanup)) throw refusal;
		throw new AggregateError([refusal, cleanup], "attached-view refusal and observer release both failed");
	}
	throw refusal;
}

export class DurableRoomsSessionBehavior {
	readonly #state: DurableRoomsSessionState;
	readonly #runtime: DurableRoomsRuntime;
	readonly #grants: RoomsSessionGrantAuthority;
	readonly #observers = new Map<Session, Observer>();
	readonly #durableGrantTokens = new Map<string, symbol>();
	readonly #invitationAdmission: RoomInvitationAdmission;

	constructor(state: DurableRoomsSessionState, runtime: DurableRoomsRuntime, grants: RoomsSessionGrantAuthority) {
		this.#state = state;
		this.#runtime = runtime;
		this.#grants = grants;
		this.#invitationAdmission = new RoomInvitationAdmission(state);
		state.onChange((revision, checkpoint) => this.#notify(revision, checkpoint));
		grants.onChange(() => {
			const snapshot = state.snapshot();
			this.#notify(snapshot.revision, snapshot.checkpoint);
		});
		runtime.onStatus(() => {
			const snapshot = state.snapshot();
			this.#notify(snapshot.revision, snapshot.checkpoint);
		});
		runtime.onOperationsInvalidated((scope) => {
			for (const [session, held] of this.#observers) {
				if (held.rights !== "admin") continue;
				if (!held.active()) {
					this.#drop(session);
					continue;
				}
				try {
					session.tell(held.observer, ROOMS_SESSION_OPERATIONS_CHANGED, [scope])
						.catch((error) => this.#deliveryFailed(session, "operations invalidation", error));
				} catch (error) {
					this.#deliveryFailed(session, "operations invalidation", error);
				}
			}
		});
		runtime.onInvitation((directory, label, link, from, locator, nick) => {
			return this.#invitationAdmission.admit({ directory, label, link, from, locator, nick }).catch((error) => {
				console.error(
					`rooms session: could not retain room invitation: ${
						error instanceof Error ? error.message : error
					}`,
				);
				throw error;
			});
		});
		runtime.onMessage((conversationId, message, editable, files, history) => {
			for (const [session, held] of this.#observers) {
				if (!held.active()) {
					this.#drop(session);
					continue;
				}
				try {
					held.delivery.queueEvent(conversationId, message, editable, files, history);
				} catch (error) {
					this.#deliveryFailed(session, "event admission", error);
				}
			}
		});
	}

	root(): Behavior {
		return this.#behavior("admin");
	}

	durableFacet(rights: RoomsSessionFacet, id: string, active: () => boolean): Behavior {
		let token = this.#durableGrantTokens.get(id);
		if (token == null) {
			token = Symbol(`durable Rooms session ${rights} grant ${id}`);
			this.#durableGrantTokens.set(id, token);
		}
		return this.#behavior(rights, active, token);
	}

	async revokeDurableFacet(id: string): Promise<void> {
		const token = this.#durableGrantTokens.get(id);
		if (token == null) return;
		const deliveries: Promise<void>[] = [];
		for (const [session, held] of this.#observers) {
			if (held.grant !== token) continue;
			deliveries.push(
				session.tell(
					held.observer,
					ROOMS_SESSION_CHANGED,
					this.#snapshotFor(held.rights, session, [{
						subject: "session-access",
						reason: "This session capability was revoked. Detach it or attach with another capability.",
					}]),
				).catch((error) => {
					if (!cleanupSettledBySessionClose(error)) {
						console.error(
							`rooms session: attached-view revocation notice failed: ${
								error instanceof Error ? error.message : error
							}`,
						);
					}
				}).finally(() => {
					this.#drop(session);
				}),
			);
		}
		await Promise.all(deliveries);
		this.#durableGrantTokens.delete(id);
	}

	#drop(session: Session): unknown | null {
		const held = this.#observers.get(session);
		if (held == null) return null;
		this.#observers.delete(session);
		let failure: unknown | null = null;
		try {
			held.stopClose();
		} catch (error) {
			if (!cleanupSettledBySessionClose(error)) failure = error;
		}
		try {
			session.release(held.observer);
		} catch (error) {
			if (!cleanupSettledBySessionClose(error)) {
				failure = failure == null ? error : retainSecondaryFailure(failure, error);
			}
		}
		if (failure != null) {
			console.error(
				`rooms session: attached-view observer cleanup failed: ${
					failure instanceof Error ? failure.message : failure
				}`,
			);
		}
		return failure;
	}

	#deliveryFailed(session: Session, operation: string, error: unknown): void {
		if (!cleanupSettledBySessionClose(error)) {
			console.error(
				`rooms session: attached-view ${operation} failed: ${error instanceof Error ? error.message : error}`,
			);
		}
		this.#drop(session);
	}

	#dropGrant(grant: symbol): void {
		for (const [session, held] of this.#observers) {
			if (held.grant === grant) this.#drop(session);
		}
	}

	#notify(revision: number, checkpoint: RoomsSessionState): void {
		if (this.#observers.size === 0) return;
		const encoded = JSON.stringify(checkpoint);
		let redacted: string | null = null;
		const pending = this.#state.pendingEffectIds();
		const issues = this.#runtime.issues().map((issue) => [issue.subject, issue.reason]);
		const connected = this.#runtime.connectedDirectories();
		let adminEffects: Argument[] | null = null;
		const liveRoomViews = this.#runtime.roomViews();
		const roomViews = JSON.stringify(liveRoomViews);
		const observedRoomViews = JSON.stringify(roomViewsVisibleTo("observe", liveRoomViews));
		const archiveShares = JSON.stringify(this.#runtime.archiveShares());
		const directoryViews = JSON.stringify(this.#runtime.directoryViews());
		for (const [session, held] of this.#observers) {
			if (!held.active()) {
				this.#drop(session);
				continue;
			}
			let checkpointText = encoded;
			let effectRows: Argument[] = [];
			if (held.rights === "admin") {
				if (adminEffects == null) adminEffects = this.#effectDetails("admin");
				effectRows = adminEffects;
			} else {
				if (redacted == null) redacted = JSON.stringify(redactRoomsSessionCapabilities(checkpoint));
				checkpointText = redacted;
			}
			const args: Argument[] = [
				BigInt(revision),
				checkpointText,
				pending,
				issues,
				connected,
				effectRows,
				this.#runtime.memberLocator(),
				held.rights === "observe" ? observedRoomViews : roomViews,
				archiveShares,
				directoryViews,
				encodeSessionAccess(
					held.rights,
					this.#state.workspaceAdoption,
					held.rights === "admin" ? this.#grants.list(session) : [],
				),
			];
			try {
				held.delivery.queueSnapshot(args);
			} catch (error) {
				this.#deliveryFailed(session, "snapshot admission", error);
			}
		}
	}

	#effectDetails(rights: RoomsSessionFacet): Argument[] {
		if (rights !== "admin") return [];
		return this.#state.pendingEffectDetails().map((effect) =>
			[
				effect.id,
				effect.kind,
				effect.kind === "external"
					? effect.intent ?? "Recover an external session operation"
					: effect.intent == null
					? "Recover an external session operation"
					: describeRoomsSessionResult(effect.kind, effect.intent),
				effect.phase,
			] as Argument
		);
	}

	#snapshotFor(
		rights: RoomsSessionFacet,
		session: Session,
		extraIssues: readonly { subject: string; reason: string }[] = [],
	): Argument[] {
		const snapshot = this.#state.snapshot();
		return encodeSessionSnapshot(
			snapshot.revision,
			checkpointVisibleTo(rights, snapshot.checkpoint),
			this.#state.pendingEffectIds(),
			[...this.#runtime.issues(), ...extraIssues],
			this.#runtime.connectedDirectories(),
			this.#effectDetails(rights),
			this.#runtime.memberLocator(),
			roomViewsVisibleTo(rights, this.#runtime.roomViews()),
			this.#runtime.archiveShares(),
			this.#runtime.directoryViews(),
			rights,
			this.#state.workspaceAdoption,
			rights === "admin" ? this.#grants.list(session) : [],
		);
	}

	#behavior(
		rights: RoomsSessionFacet,
		active: () => boolean = () => true,
		grant: symbol = Symbol("Rooms session root"),
	): Behavior {
		return (verb: string, args: Argument[]): ReturnType<Behavior> => {
			const session = currentSession();
			if (session == null) throw new Error("a Rooms session facet is reachable only over a session");
			if (!active()) {
				refuseCapabilityArguments(session, args, "this Rooms session facet was revoked");
			}
			admitSessionFacetArguments(session, verb, args);
			if (verb === ROOMS_SESSION_SNAPSHOT) {
				if (args.length !== 0) throw new Error("session snapshot takes no arguments");
				return this.#snapshotFor(rights, session);
			}
			if (verb === ROOMS_SESSION_WATCH) {
				const observer = takeSessionObserver(session, args);
				if (!this.#observers.has(session) && this.#observers.size === MAX_ATTACHED_VIEWS) {
					refuseOwnedObserver(
						session,
						observer,
						new Error("this Rooms session has reached its attached-view limit"),
					);
				}
				const priorCleanup = this.#drop(session);
				if (priorCleanup != null) refuseOwnedObserver(session, observer, priorCleanup);
				let stopClose: () => void;
				try {
					stopClose = session.onClose(() => this.#drop(session));
				} catch (error) {
					refuseOwnedObserver(session, observer, error);
				}
				const delivery: AttachedViewDelivery = new AttachedViewDelivery({
					session,
					observer,
					rights,
					current: () => this.#observers.get(session)?.delivery === delivery,
					gapSnapshot: () =>
						this.#snapshotFor(rights, session, [{
							subject: "event-gap",
							reason: "A slow attached view exceeded its bounded event queue; history is reconciling.",
						}]),
					failed: (error) => this.#deliveryFailed(session, "delivery", error),
				});
				const held: Observer = {
					observer,
					stopClose,
					active,
					grant,
					rights,
					delivery,
				};
				this.#observers.set(session, held);
				try {
					return this.#snapshotFor(rights, session);
				} catch (error) {
					const cleanup = this.#drop(session);
					if (cleanup != null) {
						throw new AggregateError(
							[error, cleanup],
							"initial session snapshot and observer cleanup both failed",
						);
					}
					throw error;
				}
			}
			if (verb === ROOMS_SESSION_REPLACE) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot replace checkpoints");
				const request = parseRoomsCheckpointRequest(args, "replaceCheckpoint");
				return this.#state.replace(request.operationId, request.baseRevision, request.checkpoint).then(
					BigInt,
				) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_ADOPT_WORKSPACE) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot adopt a workspace");
				const request = parseRoomsCheckpointRequest(args, "adoptWorkspace");
				return this.#state.adoptWorkspace(request.operationId, request.baseRevision, request.checkpoint).then(
					BigInt,
				) as ReturnType<Behavior>;
			}
			const archivedFile = dispatchArchivedFileCommand(rights, verb, args, session, this.#runtime);
			if (archivedFile !== ARCHIVED_FILE_UNHANDLED) return archivedFile;
			if (verb === ROOMS_SESSION_HISTORY) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot read archived history");
				if (
					args.length !== 3 || (args[0] !== "room" && args[0] !== "direct") ||
					typeof args[1] !== "string" || typeof args[2] !== "string"
				) throw new Error("readHistory takes a conversation kind, directory, and conversation");
				return this.#runtime.readHistory(args[0], args[1], args[2])
					.then((records) => records.map(archiveRecordRow)) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_TYPING) {
				if (rights === "observe") throw new Error("this Rooms session facet cannot send typing");
				if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "boolean") {
					throw new Error("typing takes a conversation id and a boolean");
				}
				this.#runtime.setTyping(args[0], args[1]);
				return null;
			}
			if (verb === ROOMS_SESSION_OPERATOR_SNAPSHOT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operator authority");
				if (
					args.length < 1 || args.length > 2 || typeof args[0] !== "string" ||
					(args.length === 2 && (typeof args[1] !== "string" || args[1].length > MAX_OPERATOR_QUERY))
				) {
					throw new Error("operatorSnapshot takes a capability scope and an optional search");
				}
				return this.#runtime.operatorSnapshot(args[0], args.length === 2 ? args[1] as string : "").then((
					snapshot,
				) => JSON.stringify(
					snapshot,
					(_key, value) => typeof value === "bigint" ? value.toString() : value,
				)) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_OPERATOR_RETIRE) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot change operator authority");
				if (
					args.length !== 4 || typeof args[0] !== "string" || typeof args[1] !== "string" ||
					!OPERATOR_CATEGORIES.some((category) => category === args[1]) || typeof args[2] !== "string" ||
					args[2].length > MAX_OPERATOR_QUERY || typeof args[3] !== "bigint" || args[3] < 1n ||
					args[3] > BigInt(MAX_OPERATOR_RETIRE_BATCH)
				) throw new Error("operatorRetire takes a scope, category, search, and batch limit");
				return this.#runtime.operatorRetireMatching(
					args[0],
					args[1] as (typeof OPERATOR_CATEGORIES)[number],
					args[2],
					Number(args[3]),
				).then(operatorRetireAnswer) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_OPERATIONS_SNAPSHOT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operations authority");
				if (
					args.length !== 2 || typeof args[0] !== "string" ||
					(args[1] !== "listeners" && args[1] !== "diagnostics" && args[1] !== "irc" &&
						args[1] !== "peering" &&
						args[1] !== "viz")
				) throw new Error("operationsSnapshot takes a scope and supported capability name");
				if (args[1] === "viz") {
					const snapshot = this.#runtime.vizSnapshot(args[0]);
					return JSON.stringify({ url: snapshot.url, connected: snapshot.connected });
				}
				if (args[1] === "peering") return JSON.stringify(this.#runtime.peeringSnapshot(args[0]));
				return this.#runtime.operationsSnapshot(args[0], args[1]).then((snapshot) =>
					JSON.stringify(snapshot.rows)
				) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_OPERATOR_PAGE) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot inspect operator authority");
				if (
					args.length < 3 || args.length > 4 || typeof args[0] !== "string" || typeof args[1] !== "string" ||
					!OPERATOR_CATEGORIES.some((category) => category === args[1]) || typeof args[2] !== "bigint" ||
					args[2] < 0n || args[2] > BigInt(Number.MAX_SAFE_INTEGER) ||
					(args.length === 4 && (typeof args[3] !== "string" || args[3].length > MAX_OPERATOR_QUERY))
				) throw new Error("operatorPage takes a capability scope, category, cursor, and optional search");
				return this.#runtime.operatorPage(
					args[0],
					args[1] as (typeof OPERATOR_CATEGORIES)[number],
					Number(args[2]),
					args.length === 4 ? args[3] as string : "",
				)
					.then(operatorPageAnswer) as ReturnType<Behavior>;
			}
			const attachmentCommand = dispatchAttachmentCommand(rights, verb, args, session, {
				state: this.#state,
				runtime: this.#runtime,
			});
			if (attachmentCommand !== ATTACHMENT_COMMAND_UNHANDLED) return attachmentCommand;
			if (verb === ROOMS_SESSION_COMMAND) {
				return dispatchRoomsSessionCommand(rights, args, {
					state: this.#state,
					runtime: this.#runtime,
					session,
				});
			}
			const archiveShareResult = dispatchArchiveShareCommand(rights, verb, args, this.#runtime);
			if (archiveShareResult !== ARCHIVE_SHARE_UNHANDLED) return archiveShareResult;
			if (verb === ROOMS_SESSION_RESOLVE_EFFECT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot resolve external effects");
				if (
					args.length !== 2 || typeof args[0] !== "string" ||
					(args[1] !== "committed" && args[1] !== "abandoned")
				) throw new Error("resolveEffect takes an operation id and committed or abandoned");
				validateOperationId(args[0]);
				return this.#state.resolveEffect(args[0], args[1]).then(() => null) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_RESUME_EFFECT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot resume external effects");
				if (args.length !== 1 || typeof args[0] !== "string") {
					throw new Error("resumeEffect takes one operation id");
				}
				validateOperationId(args[0]);
				const operationId = args[0];
				return resumeResultEffect(this.#state, this.#runtime, operationId).then(BigInt) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_FACET) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot delegate");
				if (args.length !== 1 || (args[0] !== "observe" && args[0] !== "interact" && args[0] !== "admin")) {
					throw new Error("facet takes observe, interact, or admin");
				}
				let live = true;
				const facetGrant = Symbol(`Rooms session ${args[0]} facet`);
				const facet = this.#behavior(args[0], () => live, facetGrant);
				const revoker = (revokeVerb: string, revokeArgs: Argument[]) => {
					if (revokeVerb !== ROOMS_SESSION_REVOKE || revokeArgs.length !== 0) {
						refuseCapabilityArguments(
							session,
							revokeArgs,
							"Rooms session facet revoker takes revoke with no arguments",
						);
					}
					live = false;
					this.#dropGrant(facetGrant);
					return null;
				};
				return spawnFacetPair(session, facet, revoker);
			}
			if (verb === ROOMS_SESSION_ISSUE_GRANT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot issue durable grants");
				if (
					args.length !== 3 || typeof args[0] !== "string" ||
					(args[1] !== "observe" && args[1] !== "interact" && args[1] !== "admin") ||
					typeof args[2] !== "string"
				) throw new Error("issueGrant takes an id, rights, and label");
				return this.#grants.issue(args[0], args[1], args[2], session).then((grant) =>
					grant.sturdyref
				) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_REVOKE_GRANT) {
				if (rights !== "admin") throw new Error("this Rooms session facet cannot revoke durable grants");
				if (args.length !== 1 || typeof args[0] !== "string") throw new Error("revokeGrant takes one grant id");
				return this.#grants.revoke(args[0]).then(() => null) as ReturnType<Behavior>;
			}
			throw new Error(`Rooms session facet has no method ${verb}`);
		};
	}
}
