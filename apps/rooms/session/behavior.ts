// OCapN facets and revision observers for one durable Rooms session.

import {
	type Argument,
	type Behavior,
	currentSession,
	Ref,
	retainSecondaryFailure,
	type Session,
} from "@glowcap/runtime";
import {
	accessOf,
	mayInteract,
	mayObserve,
	ROOMS_SESSION_ADOPT_WORKSPACE,
	ROOMS_SESSION_BRIDGE_FORM,
	ROOMS_SESSION_COMMAND,
	ROOMS_SESSION_FACET,
	ROOMS_SESSION_HISTORY,
	ROOMS_SESSION_OPERATIONS_CHANGED,
	ROOMS_SESSION_REPLACE,
	ROOMS_SESSION_RESOLVE_EFFECT,
	ROOMS_SESSION_RESUME_EFFECT,
	ROOMS_SESSION_REVOKE,
	ROOMS_SESSION_SNAPSHOT,
	ROOMS_SESSION_TYPING,
	ROOMS_SESSION_WATCH,
	type RoomsSessionAccess,
	type RoomsSessionFacet,
} from "../lib/session/client.ts";
import { archiveRecordRow } from "../lib/archive/protocol.ts";
import { redactRoomsSessionCapabilities, type RoomsSessionState } from "../lib/rooms_state.ts";
import { DurableRoomsSessionState } from "./state.ts";
import { DurableRoomsRuntime } from "./runtime.ts";
import { ResultEffectCoordinator, resumeResultEffect } from "./result_effect.ts";
import { dispatchRoomsSessionCommand } from "./command_dispatch.ts";
import { validateOperationId } from "./effects.ts";
import { ARCHIVE_SHARE_UNHANDLED, dispatchArchiveShareCommand } from "./archive_share_commands.ts";
import { dispatchGrantCommand, GRANT_COMMAND_UNHANDLED } from "./grant_commands.ts";
import { effectDetailsFor, roomViewsVisibleTo, snapshotForFacet } from "./facet_view.ts";
import { type GrantNoticeOwner, reprojectGrantViews, revokeGrantViews } from "./grant_notices.ts";
import { encodeSessionAccess } from "./snapshot_wire.ts";
import { ARCHIVED_FILE_UNHANDLED, dispatchArchivedFileCommand } from "./archive_file_commands.ts";
import { dispatchOperatorVerb, OPERATOR_VERB_UNHANDLED } from "./operator_verbs.ts";
import { ATTACHMENT_COMMAND_UNHANDLED, dispatchAttachmentCommand } from "./attachment_commands.ts";
import { cleanupSettledBySessionClose } from "../lib/capability_cleanup.ts";
import type { RoomsSessionGrantAuthority, RoomsSessionGrantPolicy } from "./grants.ts";
import { parseRoomsCheckpointRequest } from "./checkpoint_request.ts";
import { AttachedViewDelivery } from "./attached_view_delivery.ts";
import { admitSessionFacetArguments, takeSessionObserver } from "./facet_arguments.ts";
import { refuseCapabilityArguments } from "../lib/argument_custody.ts";
import { spawnFacetPair } from "./facet_pair.ts";
import { RoomInvitationAdmission } from "./invitation_admission.ts";
import { typingMessage } from "./conversation_events.ts";

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
	/** What this view may do now, re-read whenever the grant behind it changes.
	 * Not what it was issued with: a narrowing is worth having only if it
	 * reaches the view already holding the link. */
	rights: RoomsSessionAccess;
	history: boolean;
	/** Why this view is suspended, when it is. */
	note: string;
	delivery: AttachedViewDelivery;
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
	readonly #resultEffects = new ResultEffectCoordinator();

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
			for (const [session, held] of this.#hearing()) {
				if (held.rights !== "admin") continue;
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
			for (const [session, held] of this.#hearing()) {
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
		return this.#behavior(rights, active, token, () => this.#grants.policy(id));
	}

	/** See `grant_notices.ts`: both of these are about telling the views attached
	 * under one grant that what it carries has changed or gone. */
	reprojectGrant(id: string): void {
		reprojectGrantViews(id, this.#noticeOwner());
	}

	revokeDurableFacet(id: string): Promise<void> {
		return revokeGrantViews(id, this.#noticeOwner());
	}

	#noticeOwner(): GrantNoticeOwner {
		return {
			observers: this.#observers,
			tokens: this.#durableGrantTokens,
			grants: this.#grants,
			snapshotFor: (rights, session, issues, note) => this.#facetSnapshot(rights, session, issues, note),
			drop: (session) => this.#drop(session),
		};
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

	/** The attached views entitled to hear what the session is doing.
	 *
	 * Every fan-out takes its views from here rather than from the table, so
	 * sending is what has to be established and not sending is what happens by
	 * default. Walking the table directly leaves that decision to be remembered
	 * once per fan-out, and the one carrying the room's own lines is the one it
	 * costs most to forget.
	 *
	 * Two kinds of view are in the table and hear nothing. One whose grant has
	 * gone is dropped on the way past, which is the only place that sweep needs
	 * to happen because it is the only place the table is read. One that is
	 * suspended stays attached so it can be told the moment its access returns,
	 * and the two deliveries it does get are about itself rather than about the
	 * session: the snapshot announcing the pause, and the one announcing the
	 * return. Both are sent by `reprojectGrantViews`, and both carry no session,
	 * because that is what `snapshotForFacet` answers this access with.
	 *
	 * Projecting by rights is not a substitute. A paused reader who goes on
	 * receiving every line is reading the room, whatever the flags in the views
	 * handed to them say they may do.
	 *
	 * Answered as a list rather than lazily, because the sweep on the way past
	 * removes rows from the table this reads, and because a caller needs to know
	 * whether anyone is listening before it spends anything preparing what to
	 * say. There are at most `MAX_ATTACHED_VIEWS` of them. */
	#hearing(): [Session, Observer][] {
		const listening: [Session, Observer][] = [];
		for (const [session, held] of this.#observers) {
			if (!held.active()) {
				this.#drop(session);
				continue;
			}
			if (!mayObserve(held.rights)) continue;
			listening.push([session, held]);
		}
		return listening;
	}

	#dropGrant(grant: symbol): void {
		for (const [session, held] of this.#observers) {
			if (held.grant === grant) this.#drop(session);
		}
	}

	#notify(revision: number, checkpoint: RoomsSessionState): void {
		// Everything below this line is prepared for the views that will receive
		// it, so who those are is settled first. A session whose only attached
		// view is paused serializes the checkpoint, the room views, the archive
		// shares, the directories, and the handed rooms on every change, for
		// nobody.
		const listening = this.#hearing();
		if (listening.length === 0) return;
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
		const handedRooms = JSON.stringify(this.#runtime.handedRooms.list());
		for (const [session, held] of listening) {
			let checkpointText = encoded;
			let effectRows: Argument[] = [];
			if (held.rights === "admin") {
				if (adminEffects == null) adminEffects = effectDetailsFor("admin", this.#state);
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
				mayInteract(held.rights) ? roomViews : observedRoomViews,
				archiveShares,
				directoryViews,
				encodeSessionAccess(
					held.rights,
					this.#state.workspaceAdoption,
					held.rights === "admin" ? this.#grants.list(session) : [],
					held.note,
				),
				handedRooms,
			];
			try {
				held.delivery.queueSnapshot(args);
			} catch (error) {
				this.#deliveryFailed(session, "snapshot admission", error);
			}
		}
	}

	/** What one facet sees of this session right now. */
	#facetSnapshot(
		rights: RoomsSessionAccess,
		session: Session,
		extraIssues: readonly { subject: string; reason: string }[] = [],
		note = "",
	): Argument[] {
		return snapshotForFacet(rights, session, note, extraIssues, {
			state: this.#state,
			runtime: this.#runtime,
			grants: this.#grants,
		});
	}

	#behavior(
		issued: RoomsSessionFacet,
		active: () => boolean = () => true,
		grant: symbol = Symbol("Rooms session root"),
		/** What the grant behind this facet carries now. Asked on every verb
		 * rather than captured here, which is what lets an administrator narrow a
		 * link, suspend it, or hand it its history back while somebody is holding
		 * it. The root facet has no grant and is simply admin. */
		policy: (() => RoomsSessionGrantPolicy | null) | null = null,
	): Behavior {
		return (verb: string, args: Argument[]): ReturnType<Behavior> => {
			const session = currentSession();
			if (session == null) throw new Error("a Rooms session facet is reachable only over a session");
			if (!active()) {
				refuseCapabilityArguments(session, args, "this Rooms session facet was revoked");
			}
			const carried = policy?.() ?? null;
			const rights: RoomsSessionAccess = carried == null ? issued : accessOf(carried);
			const history = carried == null ? true : carried.history;
			const note = carried?.note ?? "";
			admitSessionFacetArguments(session, verb, args);
			if (verb === ROOMS_SESSION_SNAPSHOT) {
				if (args.length !== 0) throw new Error("session snapshot takes no arguments");
				return this.#facetSnapshot(rights, session, [], note);
			}
			// A suspended link still answers for itself, and does nothing else.
			// Watching is left open with it so a view already attached is told the
			// moment the suspension lifts, rather than having to poll for it. Every
			// other verb is refused here rather than in each dispatcher, so a facet
			// carrying nothing cannot be reached through a route nobody thought to
			// gate.
			//
			// Asked the way the fan-outs ask it, and for the same reason: naming the
			// one rung that may do nothing leaves every rung nobody has thought of
			// yet on the other side of this, admitted through a door that was meant
			// to be shut.
			if (!mayObserve(rights) && verb !== ROOMS_SESSION_WATCH) {
				refuseCapabilityArguments(
					session,
					args,
					note === ""
						? "this Rooms session capability is suspended"
						: `this Rooms session capability is suspended: ${note}`,
				);
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
					// Built from what this view carries now, not from what it carried
					// when it attached. A gap snapshot is made at the moment a slow
					// view overflows its queue, which can be long after its grant was
					// narrowed, and the access it is built with decides whether the
					// checkpoint in it is redacted and whether the session's own
					// grants are listed in it. Reading the ledger at each use rather
					// than capturing it is what the rest of this file does, and
					// `retier` on the delivery beside this exists for the same reason.
					gapSnapshot: () => {
						const current = this.#observers.get(session);
						return this.#facetSnapshot(current?.rights ?? rights, session, [{
							subject: "event-gap",
							reason: "A slow attached view exceeded its bounded event queue; history is reconciling.",
						}], current?.note ?? note);
					},
					failed: (error) => this.#deliveryFailed(session, "delivery", error),
				});
				const held: Observer = {
					observer,
					stopClose,
					active,
					grant,
					history,
					note,
					rights,
					delivery,
				};
				this.#observers.set(session, held);
				try {
					// The note travels with this one too. Attaching is how a browser
					// that was not here when the pause happened finds out about it,
					// and it is the only route a reload takes — so leaving it off
					// here made a pause something you had to be watching to learn.
					return this.#facetSnapshot(rights, session, [], note);
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
			const archivedFile = dispatchArchivedFileCommand(history, verb, args, session, this.#runtime);
			if (archivedFile !== ARCHIVED_FILE_UNHANDLED) return archivedFile;
			if (verb === ROOMS_SESSION_HISTORY) {
				if (!history) throw new Error("this Rooms session facet cannot read archived history");
				if (
					args.length !== 3 || (args[0] !== "room" && args[0] !== "direct") ||
					typeof args[1] !== "string" || typeof args[2] !== "string"
				) throw new Error("readHistory takes a conversation kind, directory, and conversation");
				return this.#runtime.readHistory(args[0], args[1], args[2])
					.then((records) => records.map(archiveRecordRow)) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_BRIDGE_FORM) {
				// The declared form carries no secrets, so any facet may read it
				// the way any member asks the room itself. Submitting stays behind
				// the command's own interact gate.
				if (args.length !== 1 || typeof args[0] !== "string") {
					throw new Error("roomBridgeForm takes a conversation id");
				}
				return this.#runtime.roomActions.bridgeForm(args[0])
					.then((form) => form == null ? "" : JSON.stringify(form)) as ReturnType<Behavior>;
			}
			if (verb === ROOMS_SESSION_TYPING) {
				if (!mayInteract(rights)) throw new Error("this Rooms session facet cannot send typing");
				if (args.length !== 2 || typeof args[0] !== "string" || typeof args[1] !== "boolean") {
					throw new Error("typing takes a conversation id and a boolean");
				}
				if (this.#runtime.roomActions.setTyping(args[0], args[1])) {
					const message = typingMessage("Another attached view", args[1]);
					for (const [attached, held] of this.#observers) {
						if (attached === session) continue;
						if (!held.active()) {
							this.#drop(attached);
							continue;
						}
						try {
							held.delivery.queueEvent(args[0], message, false, [], null);
						} catch (error) {
							this.#deliveryFailed(attached, "typing event admission", error);
						}
					}
				}
				return null;
			}
			const operatorVerb = dispatchOperatorVerb(rights, verb, args, this.#runtime);
			if (operatorVerb !== OPERATOR_VERB_UNHANDLED) return operatorVerb;
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
					resultEffects: this.#resultEffects,
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
				return this.#resultEffects.run(
					operationId,
					null,
					() => resumeResultEffect(this.#state, this.#runtime, operationId),
				).then(BigInt) as ReturnType<Behavior>;
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
			const grantCommand = dispatchGrantCommand(rights, verb, args, session, {
				grants: this.#grants,
				reproject: (id) => this.reprojectGrant(id),
			});
			if (grantCommand !== GRANT_COMMAND_UNHANDLED) return grantCommand;
			throw new Error(`Rooms session facet has no method ${verb}`);
		};
	}
}
