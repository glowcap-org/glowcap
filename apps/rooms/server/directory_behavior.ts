// The directory behavior for one connection, and the inspect snapshot of it.
//
// `open`/`enter` return a live reference to a room bound to that client's
// connection. Callers still go through `main.ts`.

import {
	type Argument,
	type Behavior,
	currentSession,
	designatorHostPort,
	parseLocator,
	Ref,
	type Session,
	TRANSPORT_WEBRTC,
} from "@pancake/runtime";
import { isUriLocator } from "../lib/locator.ts";
import {
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_ROOM_MANAGERS,
	NO_SUCH_ROOM,
	NOT_REGISTERED,
	NOT_YOUR_LOCATOR,
	PEER_OFFLINE,
	ROOM_EXISTS,
	ROOM_TOO_LONG,
	RoomError,
} from "../lib/errors.ts";
import { isManagedRoomId, MAX_DM_INBOXES, MAX_ROOM, nickRefusal } from "../lib/limits.ts";
import {
	isRoomEntry,
	isRoomPolicy,
	isRoomSpeaking,
	isRoomVisibility,
	OPEN_ROOM_POLICY,
	PRIVATE_ROOM_POLICY,
	publicMembershipKind,
	roomIsListed,
	roomPoliciesEqual,
	type RoomPolicy,
	roomPublicMayEnter,
} from "../lib/room/policy.ts";
import { isRegistrationId } from "../lib/directory_publications.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import {
	ADVERTISED_LOCATION,
	DIRECT_REQUESTED,
	ENTER,
	ENTER_PUBLICATION,
	INTRODUCE,
	LINK,
	LIST,
	LIST_PUBLICATIONS,
	MEMBER_REGISTRATION,
	NOTIFY,
	OFFER_INBOX,
	OPEN,
	OPEN_MANAGED,
	OPEN_PRIVATE_LINK,
	REGISTER,
	REQUEST_DIRECT,
	WATCH,
	WATCH_PUBLICATIONS,
} from "../lib/protocol.ts";
import { RoomLinks } from "./room_links.ts";
import { roomBehavior } from "./room.ts";
import { linkedRoomBehavior } from "./room_link.ts";
import { roomManagerBootstrapBehavior } from "./room_manager.ts";
import type { RoomServerContext } from "./context.ts";
import {
	claimsOwnLocator,
	directRequestNoticeDue,
	registeredByAnother,
	registerMember,
	registrationOf,
} from "./introductions.ts";
import { directoryWatchSnapshot, roomSnapshot } from "./discovery.ts";
import { dropWatchers } from "./watchers.ts";
import { nickKey, roomKey, type RoomState } from "./registry.ts";
import {
	DIRECTORY_SIGNALING_CAPABILITY_VERBS,
	DIRECTORY_SIGNALING_UNHANDLED,
	dispatchDirectorySignaling,
} from "./directory_signaling.ts";

function publicRoomEntrance(ctx: RoomServerContext, state: RoomState, links: RoomLinks | null): Behavior {
	const managed = links?.managedRoom(state.key) ?? null;
	const active = managed === null || links === null
		? () => roomIsListed(state.policy) && roomPublicMayEnter(state.policy)
		: () => links.managedRoomGenerationIsCurrent(managed.id, managed.generation);
	return roomBehavior(ctx, state, ctx.history, links, {
		membershipKind: publicMembershipKind(state.policy),
		active,
	});
}

function spawnRoomOpening(
	ctx: RoomServerContext,
	session: Session,
	state: RoomState,
	roomLinks: RoomLinks | null,
	managerLinks: RoomLinks | null,
): Ref | [Ref, Ref] {
	const room = session.spawn(roomBehavior(ctx, state, ctx.history, roomLinks));
	if (managerLinks === null) return room;
	try {
		return [
			room,
			session.spawn(roomManagerBootstrapBehavior(state.key, managerLinks, {
				name: state.name,
				policy: state.policy,
			})),
		];
	} catch (error) {
		ctx.journal.release(session, room, "unreturned room capability");
		throw error;
	}
}

/** Prepare every capability an open returns before filing the room, then make
 * the registry mutation the commit point. A refused spawn or registration
 * therefore leaves neither an orphaned export nor a room/name/quota row. */
export function openNewRoom(
	ctx: RoomServerContext,
	session: Session,
	state: RoomState,
	roomLinks: RoomLinks | null,
	managerLinks: RoomLinks | null,
): Ref | [Ref, Ref] {
	const opening = spawnRoomOpening(ctx, session, state, roomLinks, managerLinks);
	try {
		ctx.live.registerRoom(state);
		return opening;
	} catch (error) {
		for (const ref of Array.isArray(opening) ? opening : [opening]) {
			ctx.journal.release(session, ref, "uncommitted room capability");
		}
		throw error;
	}
}

export function refuseDirectoryCall(session: Session, args: readonly Argument[], error: unknown): never {
	throwAfterReleasingCapabilities(session, args, error);
}

const DIRECTORY_CAPABILITY_VERBS = new Set([
	REGISTER,
	OFFER_INBOX,
	WATCH,
	WATCH_PUBLICATIONS,
	...DIRECTORY_SIGNALING_CAPABILITY_VERBS,
]);

/** The directory behavior for one connection. `open`/`enter` return a live
 * reference to a room — the per-connection room view spawned here — so the room
 * a client holds is bound to that client's connection. */
export function directoryBehavior(
	ctx: RoomServerContext,
	links?: RoomLinks,
	advertisedLocation?: (session: Session) => string,
): Behavior {
	const { history, live, watchers } = ctx;
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		// The directory belongs to the Host rather than to any one connection, so
		// the caller is the session whose turn is running. Everything below keys
		// on that: a registration, an introduction and a signaling exchange are
		// all facts about a connection.
		const session = currentSession();
		if (session == null) throw new Error("the directory is reachable only over a session");
		if (!DIRECTORY_CAPABILITY_VERBS.has(verb) && hasCapabilityArguments(args)) {
			refuseDirectoryCall(session, args, new Error(`directory ${verb} does not take capability arguments`));
		}
		if (verb === REGISTER) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const locator = typeof args[1] === "string" ? args[1] : "";
			const inbox = args[2];
			if (args.length !== 3 || nick.length === 0 || locator.length === 0 || !(inbox instanceof Ref)) {
				refuseDirectoryCall(session, args, new Error("register needs a nick, locator, and inbox capability"));
			}
			try {
				// Only the directory can hold this: every member it introduces files an
				// inbox under this name and keeps it for good, so a name granted here
				// without a ceiling is an allocation the caller spends in somebody
				// else's process.
				const unregisterable = nickRefusal(nick);
				if (unregisterable != null) throw new RoomError(NICK_TOO_LONG, unregisterable);
				let claimed: ReturnType<typeof parseLocator> | null = null;
				try {
					if (isUriLocator(locator)) claimed = parseLocator(locator);
					else designatorHostPort(locator);
				} catch (cause) {
					throw new Error("register locator must be hostname:port or an ocapn:// URI", { cause });
				}
				if (!claimsOwnLocator(session, locator)) {
					throw new RoomError(
						NOT_YOUR_LOCATOR,
						`the locator "${locator}" does not name the connection registering it`,
					);
				}
				if (registeredByAnother(live, session, nick)) {
					throw new RoomError(
						NICK_TAKEN,
						`"${nick}" is registered by another member; it frees when they disconnect`,
					);
				}
				// A `webrtc` designator routes signaling, and an unkeyed connection's
				// claim to one cannot be verified (`claimsOwnLocator` says why, and
				// what full verification would take). What *can* be refused without any
				// keys is a claim to a designator another live registration already
				// routes by: accepting it overwrote the holder's row, and every DM
				// bring-up aimed at them landed in the claimant's signaling inbox.
				// First writer holds the designator while their connection stands.
				if (claimed?.transport === TRANSPORT_WEBRTC) {
					const holderKey = live.webrtcDesignators.get(claimed.designator);
					const holder = holderKey === undefined ? undefined : live.introductions.get(holderKey);
					if (holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen) {
						throw new RoomError(
							NOT_YOUR_LOCATOR,
							`that webrtc designator is already registered to "${holder.nick}"`,
						);
					}
				}
			} catch (error) {
				ctx.journal.release(session, inbox);
				throw error;
			}
			// The reply is the name capability: the holding of the name, which is
			// what lets its holder be this member from another connection.
			return registerMember(ctx, nick, locator, inbox, session);
		}
		if (verb === OFFER_INBOX) {
			const forNick = typeof args[0] === "string" ? args[0] : "";
			const forRegistrationId = typeof args[1] === "string" ? args[1] : "";
			const offered = args[2];
			if (args.length !== 3 || !(offered instanceof Ref)) {
				refuseDirectoryCall(
					session,
					args,
					new Error("offerInbox needs a nick, registration ID, and inbox capability"),
				);
			}
			const unofferable = nickRefusal(forNick);
			if (unofferable != null || !isRegistrationId(forRegistrationId)) {
				ctx.journal.release(session, offered);
				throw new RoomError(NICK_TOO_LONG, unofferable ?? "offerInbox has an invalid registration ID");
			}
			// A member may only decide who reaches *it*, so the offer is filed under
			// the offering connection's own registration. An unregistered caller has
			// no record to file it under, which is the refusal.
			const own = registrationOf(live, session);
			if (own == null) {
				ctx.journal.release(session, offered);
				throw new RoomError(NOT_REGISTERED, "offerInbox needs a registered name");
			}
			const waiting = live.introductions.get(nickKey(forNick));
			if (waiting?.registrationId !== forRegistrationId) {
				ctx.journal.release(session, offered);
				throw new RoomError(PEER_OFFLINE, `the registration for "${forNick}" changed before its inbox arrived`);
			}
			const key = forRegistrationId;
			// The row is one per peer the member has offered for, and the member
			// chooses the peers, so the directory holds the same ceiling its members
			// do rather than growing a map on their word.
			if (!own.inboxes.has(key) && own.inboxes.size >= MAX_DM_INBOXES) {
				ctx.journal.release(session, offered);
				throw new Error(`a member may offer at most ${MAX_DM_INBOXES} inboxes`);
			}
			// The Host identity is already valid across this host's sessions; storing
			// it preserves exactly the capability the member offered.
			const token = offered;
			const prior = own.inboxes.get(key);
			own.inboxes.set(key, token);
			if (prior !== undefined) ctx.journal.release(session, prior);
			// Whoever was told to wait can ask again now.
			waiting.registrar.tell(waiting.inbox, NOTIFY, ["introducible", own.nick, own.registrationId]).catch(
				() => {},
			);
			return null;
		}
		const signaling = dispatchDirectorySignaling(live, verb, args, session);
		if (signaling !== DIRECTORY_SIGNALING_UNHANDLED) return signaling;
		if (verb === REQUEST_DIRECT) {
			if (
				args.length !== 2 || typeof args[0] !== "string" || nickRefusal(args[0]) != null ||
				!isRegistrationId(args[1])
			) {
				for (const argument of args) if (argument instanceof Ref) ctx.journal.release(session, argument);
				throw new Error("requestDirect takes a valid registered name and its registration ID");
			}
			const nick = args[0];
			const intro = live.introductions.get(nickKey(nick));
			if (intro == null || intro.registrationId !== args[1] || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			const caller = registrationOf(live, session);
			if (caller == null) {
				throw new RoomError(NOT_REGISTERED, "requestDirect needs a registered name");
			}
			const requestKey = caller.registrationId;
			if (directRequestNoticeDue(intro.directRequests, requestKey, performance.now())) {
				intro.registrar.tell(intro.inbox, NOTIFY, [DIRECT_REQUESTED, caller.nick, caller.registrationId]).catch(
					(error) => {
						ctx.journal.note("a reciprocal direct request notification failed", error);
					},
				);
			}
			return null;
		}
		if (verb === MEMBER_REGISTRATION) {
			if (args.length !== 1 || typeof args[0] !== "string" || nickRefusal(args[0]) != null) {
				for (const argument of args) if (argument instanceof Ref) ctx.journal.release(session, argument);
				throw new Error("memberRegistration takes one valid registered name");
			}
			const intro = live.introductions.get(nickKey(args[0]));
			if (intro == null || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${args[0]}" is registered`);
			}
			return intro.registrationId;
		}
		if (verb === INTRODUCE) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const expectedRegistrationId = typeof args[1] === "string" ? args[1] : "";
			if (
				args.length !== 2 || nickRefusal(nick) != null || !isRegistrationId(expectedRegistrationId)
			) {
				for (const argument of args) if (argument instanceof Ref) ctx.journal.release(session, argument);
				throw new Error("introduce takes a valid registered name and its registration ID");
			}
			const intro = live.introductions.get(nickKey(nick));
			// The same liveness `register` reads: a holder whose connection has gone
			// but whose close callback has not run yet is nobody to be introduced to.
			if (intro == null || intro.registrationId !== expectedRegistrationId || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			// The caller's registered nick is the key the member filed their inbox
			// under, so an unregistered caller has no name one could have been minted.
			const caller = registrationOf(live, session);
			if (caller == null) {
				throw new RoomError(NOT_REGISTERED, "introduce needs a registered name");
			}
			const requestKey = caller.registrationId;
			const inbox = intro.inboxes.get(requestKey);
			if (inbox === undefined) {
				// Genuine first contact. Ask the member for an inbox for this caller
				// and tell the caller to come back only after the target session has
				// accepted that notification locally.
				return intro.registrar.tell(
					intro.inbox,
					NOTIFY,
					["mintInboxFor", caller.nick, caller.registrationId],
				).then(
					() => {
						throw new RoomError(
							INTRODUCTION_PENDING,
							`"${nick}" has been asked for an inbox for "${caller.nick}"; try again`,
						);
					},
					(error) => {
						ctx.journal.note(`could not ask ${nick} for a direct-message inbox`, error);
						throw new RoomError(PEER_OFFLINE, `"${nick}" could not be reached for direct messages`);
					},
				);
			}
			// Returning a reference whose home is the directory-to-member connection
			// trips the transparent gifter: the caller gets a give, not a relay.
			return inbox;
		}
		const name = typeof args[0] === "string" ? args[0] : "";
		if (verb === LINK) {
			if (args.length !== 1 || name.length === 0 || name.length > MAX_ROOM) {
				throw new Error(`link needs one room name of at most ${MAX_ROOM} characters`);
			}
			if (links == null) throw new Error("this directory does not publish room links");
			const entry = live.publicRooms.get(roomKey(name));
			if (entry === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			if (entry.kind !== "local") throw new Error("a foreign room is linked by its source directory");
			const link = links.currentRoomLink(entry.state.key, session);
			if (link === null) throw new Error("that room has no link; a room manager must create one");
			return link;
		}
		if (verb === OPEN_PRIVATE_LINK) {
			if (links === undefined) throw new Error("this directory does not publish room links");
			if (args.length !== 1 || !isManagedRoomId(name)) {
				throw new Error("openPrivateLink needs one opaque private room key");
			}
			return links.link(name, session);
		}
		if (verb === OPEN || verb === OPEN_MANAGED) {
			const managerLinks = verb === OPEN_MANAGED ? links ?? null : null;
			const managed = verb === OPEN_MANAGED;
			if (managed) {
				if (
					args.length !== 5 || typeof args[0] !== "string" || !isRoomVisibility(args[1]) ||
					!isRoomEntry(args[2]) || !isRoomSpeaking(args[3]) ||
					typeof args[4] !== "string" || !isManagedRoomId(args[4])
				) throw new Error("openManaged needs a room name, three policy modes, and opaque room id");
			} else if (
				args.length < 1 || args.length > 3 || typeof args[0] !== "string" ||
				(args.length >= 2 && typeof args[1] !== "boolean") ||
				(args.length === 3 && (args[1] !== true || typeof args[2] !== "string"))
			) throw new Error("open needs a room name, optional private flag, and optional recovery key");
			if (name.length === 0) throw new Error("open needs a room name");
			if (verb === OPEN_MANAGED && managerLinks === null) {
				throw new RoomError(NO_ROOM_MANAGERS, "this directory does not publish room managers");
			}
			if (name.length > MAX_ROOM) {
				throw new RoomError(
					ROOM_TOO_LONG,
					`a room name may be at most ${MAX_ROOM} characters`,
				);
			}
			const candidate = managed
				? { visibility: args[1], entry: args[2], speaking: args[3] }
				: args[1] === true
				? PRIVATE_ROOM_POLICY
				: OPEN_ROOM_POLICY;
			if (!isRoomPolicy(candidate)) throw new Error("openManaged names no supported room access state");
			const policy: RoomPolicy = candidate;
			const recoveryKey = managed ? args[4] : args[2];
			if (
				policy.visibility === "secret" && recoveryKey != null &&
				(typeof recoveryKey !== "string" || !isManagedRoomId(recoveryKey))
			) {
				throw new Error("a private room recovery key is invalid");
			}
			// Only a public name is taken, because only a public name is a way in.
			// Two readers may each keep a private room called "notes", and neither
			// learns that the other has one — which is also why this cannot answer
			// "already exists" for a private name: that answer is itself the leak.
			if (
				roomIsListed(policy) &&
				(live.publicRoomNameTaken(name) || links?.hasRegisteredPublicRoom(name) === true)
			) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			if (typeof recoveryKey === "string") {
				const recovered = live.rooms.get(recoveryKey);
				if (recovered != null) {
					if (recovered.name !== name || !roomPoliciesEqual(recovered.policy, policy)) {
						throw new Error("that room id already belongs to a different managed room state");
					}
					return spawnRoomOpening(ctx, session, recovered, links ?? null, managerLinks);
				}
			}
			const state = live.makeRoomState(name, session, {
				policy,
				...(typeof recoveryKey === "string" ? { key: recoveryKey } : {}),
				topic: links?.topic(typeof recoveryKey === "string" ? recoveryKey : name) ?? "",
			});
			return openNewRoom(ctx, session, state, links ?? null, managerLinks);
		}
		if (verb === ENTER) {
			if (args.length !== 1 || typeof args[0] !== "string" || name.length === 0) {
				throw new Error("enter needs one room name");
			}
			const entry = live.publicRooms.get(roomKey(name));
			if (entry === undefined) {
				const managed = links?.managedRoomForPublicName(name) ?? null;
				if (managed !== null && links != null) {
					if (!roomPublicMayEnter(managed.policy)) {
						throw new RoomError(
							NO_SUCH_ROOM,
							`room "${name}" is invite-only; use an invitation or room link`,
						);
					}
					const roomLinks = links;
					return session.spawn(
						linkedRoomBehavior(
							ctx,
							managed.id,
							() => roomLinks,
							history,
							{
								membershipKind: publicMembershipKind(managed.policy),
								active: () => roomLinks.managedRoomGenerationIsCurrent(managed.id, managed.generation),
							},
						),
					);
				}
				if (links?.hasRegisteredPublicRoom(name) === true) {
					return session.spawn(linkedRoomBehavior(ctx, name, () => links, history));
				}
				throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			}
			if (entry.kind === "local" && !roomPublicMayEnter(entry.state.policy)) {
				throw new RoomError(NO_SUCH_ROOM, `room "${name}" is invite-only; use an invitation or room link`);
			}
			return entry.kind === "local"
				? session.spawn(publicRoomEntrance(ctx, entry.state, links ?? null))
				: entry.kind === "bridge"
				? session.spawn(entry.bridge.roomBehavior())
				: entry.room;
		}
		if (verb === ENTER_PUBLICATION) {
			const id = typeof args[0] === "string" ? args[0] : "";
			if (args.length !== 1 || id === "") throw new Error("enterPublication needs one publication id");
			const entry = live.publicRoomById(id);
			if (entry === null) throw new RoomError(NO_SUCH_ROOM, "that room publication is no longer current");
			if (entry.kind === "local" && !roomPublicMayEnter(entry.state.policy)) {
				throw new RoomError(
					NO_SUCH_ROOM,
					`room "${entry.name}" is invite-only; use an invitation or room link`,
				);
			}
			return entry.kind === "local"
				? session.spawn(publicRoomEntrance(ctx, entry.state, links ?? null))
				: entry.kind === "bridge"
				? session.spawn(entry.bridge.roomBehavior())
				: entry.room;
		}
		if (verb === LIST) {
			if (args.length !== 0) throw new Error("list takes no arguments");
			return roomSnapshot(ctx, "baseline").rows;
		}
		if (verb === LIST_PUBLICATIONS) {
			if (args.length !== 0) throw new Error("listPublications takes no arguments");
			return roomSnapshot(ctx, "publication").rows;
		}
		if (verb === ADVERTISED_LOCATION) {
			if (args.length !== 0) throw new Error("advertisedLocation takes no arguments");
			if (advertisedLocation === undefined) throw new Error("this directory does not publish a location");
			return advertisedLocation(session);
		}
		if (verb === WATCH || verb === WATCH_PUBLICATIONS) {
			const observer = args[0];
			if (args.length !== 1 || !(observer instanceof Ref)) {
				refuseDirectoryCall(session, args, new Error("watch needs exactly one inbox capability"));
			}
			// One live view of the directory per connection. Every room event walks
			// this list, so a connection able to add rows to it without limit would
			// make each join and departure anywhere on this server do its work again
			// for every row that connection had asked for. Watching again replaces,
			// the same way a connection re-claiming its place in a room replaces its
			// membership rather than being seated twice.
			dropWatchers(watchers, session);
			let admitted = false;
			try {
				watchers.push({
					observer,
					session,
					records: verb === WATCH_PUBLICATIONS ? "publication" : "baseline",
				});
				admitted = true;
				return verb === WATCH_PUBLICATIONS
					? directoryWatchSnapshot(ctx, "publication")
					: roomSnapshot(ctx, "baseline").rows;
			} catch (error) {
				if (admitted) dropWatchers(watchers, session);
				else ctx.journal.release(session, observer, "refused directory watcher");
				throw error;
			}
		}
		throw new Error(`directory has no method ${verb}`);
	};
}
