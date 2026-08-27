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
import { noteTrouble, troubleRows } from "./journal.ts";
import {
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	NO_SUCH_ROOM,
	NOT_REGISTERED,
	NOT_YOUR_LOCATOR,
	PEER_OFFLINE,
	ROOM_EXISTS,
	ROOM_TOO_LONG,
	RoomError,
} from "../lib/errors.ts";
import { isPrivateRoomKey, MAX_DM_INBOXES, MAX_ROOM, nickRefusal } from "../lib/limits.ts";
import { isRegistrationId } from "../lib/directory_publications.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import {
	ADVERTISED_LOCATION,
	DIRECT_REQUESTED,
	DIRECTORY,
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
	OPEN_PRIVATE_LINK,
	REGISTER,
	REQUEST_DIRECT,
	SNAPSHOT,
	WATCH,
	WATCH_PUBLICATIONS,
} from "../lib/protocol.ts";
import { RoomLinks } from "./room_links.ts";
import { roomBehavior } from "./room.ts";
import {
	claimsOwnLocator,
	directRequestNoticeDue,
	registeredByAnother,
	registerMember,
	registrationOf,
} from "./introductions.ts";
import { directoryWatchSnapshot, roomSnapshot } from "./discovery.ts";
import { dropWatchers, watchers } from "./watchers.ts";
import {
	handBack,
	heldRoomLinks,
	introductions,
	makeRoomState,
	nickKey,
	publicRoomById,
	publicRoomNameTaken,
	publicRooms,
	registerRoom,
	roomKey,
	rooms,
	webrtcDesignators,
} from "./registry.ts";
import {
	DIRECTORY_SIGNALING_CAPABILITY_VERBS,
	DIRECTORY_SIGNALING_UNHANDLED,
	dispatchDirectorySignaling,
} from "./directory_signaling.ts";

function refuseDirectoryCall(session: Session, args: readonly Argument[], error: unknown): never {
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
export function directoryBehavior(links?: RoomLinks, advertisedLocation?: (session: Session) => string): Behavior {
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
				if (registeredByAnother(session, nick)) {
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
					const holderKey = webrtcDesignators.get(claimed.designator);
					const holder = holderKey === undefined ? undefined : introductions.get(holderKey);
					if (holder !== undefined && holder.registrar !== session && holder.registrar.sessionOpen) {
						throw new RoomError(
							NOT_YOUR_LOCATOR,
							`that webrtc designator is already registered to "${holder.nick}"`,
						);
					}
				}
			} catch (error) {
				handBack(session, inbox);
				throw error;
			}
			// The reply is the name capability: the holding of the name, which is
			// what lets its holder be this member from another connection.
			return registerMember(nick, locator, inbox, session);
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
				handBack(session, offered);
				throw new RoomError(NICK_TOO_LONG, unofferable ?? "offerInbox has an invalid registration ID");
			}
			// A member may only decide who reaches *it*, so the offer is filed under
			// the offering connection's own registration. An unregistered caller has
			// no record to file it under, which is the refusal.
			const own = registrationOf(session);
			if (own == null) {
				handBack(session, offered);
				throw new RoomError(NOT_REGISTERED, "offerInbox needs a registered name");
			}
			const waiting = introductions.get(nickKey(forNick));
			if (waiting?.registrationId !== forRegistrationId) {
				handBack(session, offered);
				throw new RoomError(PEER_OFFLINE, `the registration for "${forNick}" changed before its inbox arrived`);
			}
			const key = forRegistrationId;
			// The row is one per peer the member has offered for, and the member
			// chooses the peers, so the directory holds the same ceiling its members
			// do rather than growing a map on their word.
			if (!own.inboxes.has(key) && own.inboxes.size >= MAX_DM_INBOXES) {
				handBack(session, offered);
				throw new Error(`a member may offer at most ${MAX_DM_INBOXES} inboxes`);
			}
			// The Host identity is already valid across this host's sessions; storing
			// it preserves exactly the capability the member offered.
			const token = offered;
			const prior = own.inboxes.get(key);
			own.inboxes.set(key, token);
			if (prior !== undefined) handBack(session, prior);
			// Whoever was told to wait can ask again now.
			waiting.registrar.tell(waiting.inbox, NOTIFY, ["introducible", own.nick, own.registrationId]).catch(
				() => {},
			);
			return null;
		}
		const signaling = dispatchDirectorySignaling(verb, args, session);
		if (signaling !== DIRECTORY_SIGNALING_UNHANDLED) return signaling;
		if (verb === REQUEST_DIRECT) {
			if (
				args.length !== 2 || typeof args[0] !== "string" || nickRefusal(args[0]) != null ||
				!isRegistrationId(args[1])
			) {
				for (const argument of args) if (argument instanceof Ref) handBack(session, argument);
				throw new Error("requestDirect takes a valid registered name and its registration ID");
			}
			const nick = args[0];
			const intro = introductions.get(nickKey(nick));
			if (intro == null || intro.registrationId !== args[1] || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			const caller = registrationOf(session);
			if (caller == null) {
				throw new RoomError(NOT_REGISTERED, "requestDirect needs a registered name");
			}
			const requestKey = caller.registrationId;
			if (directRequestNoticeDue(intro.directRequests, requestKey, performance.now())) {
				intro.registrar.tell(intro.inbox, NOTIFY, [DIRECT_REQUESTED, caller.nick, caller.registrationId]).catch(
					(error) => {
						noteTrouble("a reciprocal direct request notification failed", error);
					},
				);
			}
			return null;
		}
		if (verb === MEMBER_REGISTRATION) {
			if (args.length !== 1 || typeof args[0] !== "string" || nickRefusal(args[0]) != null) {
				for (const argument of args) if (argument instanceof Ref) handBack(session, argument);
				throw new Error("memberRegistration takes one valid registered name");
			}
			const intro = introductions.get(nickKey(args[0]));
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
				for (const argument of args) if (argument instanceof Ref) handBack(session, argument);
				throw new Error("introduce takes a valid registered name and its registration ID");
			}
			const intro = introductions.get(nickKey(nick));
			// The same liveness `register` reads: a holder whose connection has gone
			// but whose close callback has not run yet is nobody to be introduced to.
			if (intro == null || intro.registrationId !== expectedRegistrationId || !intro.registrar.sessionOpen) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			// The caller's registered nick is the key the member filed their inbox
			// under, so an unregistered caller has no name one could have been minted.
			const caller = registrationOf(session);
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
						noteTrouble(`could not ask ${nick} for a direct-message inbox`, error);
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
			const entry = publicRooms.get(roomKey(name));
			if (entry === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			if (entry.kind !== "local") throw new Error("a foreign room is linked by its source directory");
			return links.link(entry.state.name, session);
		}
		if (verb === OPEN_PRIVATE_LINK) {
			if (links === undefined) throw new Error("this directory does not publish room links");
			if (args.length !== 1 || !isPrivateRoomKey(name)) {
				throw new Error("openPrivateLink needs one opaque private room key");
			}
			return links.link(name, session);
		}
		if (verb === OPEN) {
			if (
				args.length < 1 || args.length > 3 || typeof args[0] !== "string" ||
				(args.length >= 2 && typeof args[1] !== "boolean") ||
				(args.length === 3 && (args[1] !== true || typeof args[2] !== "string"))
			) {
				throw new Error("open needs a room name, optional private flag, and optional recovery key");
			}
			if (name.length === 0) throw new Error("open needs a room name");
			if (name.length > MAX_ROOM) {
				throw new RoomError(
					ROOM_TOO_LONG,
					`a room name may be at most ${MAX_ROOM} characters`,
				);
			}
			// Private is asked for at the moment a room is made and never after:
			// a room that could be made private later would already have been
			// listed, and one that could be opened up would surprise the people
			// who were invited into it.
			const wantsPrivate = args[1] === true;
			const recoveryKey = args[2];
			if (
				wantsPrivate && recoveryKey != null &&
				(typeof recoveryKey !== "string" || !isPrivateRoomKey(recoveryKey))
			) {
				throw new Error("a private room recovery key is invalid");
			}
			// Only a public name is taken, because only a public name is a way in.
			// Two readers may each keep a private room called "notes", and neither
			// learns that the other has one — which is also why this cannot answer
			// "already exists" for a private name: that answer is itself the leak.
			if (!wantsPrivate && publicRoomNameTaken(name)) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			if (wantsPrivate && typeof recoveryKey === "string") {
				const recovered = rooms.get(recoveryKey);
				if (recovered != null) return session.spawn(roomBehavior(recovered));
			}
			const state = makeRoomState(name, session, {
				private: wantsPrivate,
				...(typeof recoveryKey === "string" ? { key: recoveryKey } : {}),
				topic: links?.topic(typeof recoveryKey === "string" ? recoveryKey : name) ?? "",
			});
			registerRoom(state);
			return session.spawn(roomBehavior(state));
		}
		if (verb === ENTER) {
			if (args.length !== 1 || typeof args[0] !== "string" || name.length === 0) {
				throw new Error("enter needs one room name");
			}
			const entry = publicRooms.get(roomKey(name));
			if (entry === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			return entry.kind === "local"
				? session.spawn(roomBehavior(entry.state))
				: entry.kind === "bridge"
				? session.spawn(entry.bridge.roomBehavior())
				: entry.room;
		}
		if (verb === ENTER_PUBLICATION) {
			const id = typeof args[0] === "string" ? args[0] : "";
			if (args.length !== 1 || id === "") throw new Error("enterPublication needs one publication id");
			const entry = publicRoomById(id);
			if (entry === null) throw new RoomError(NO_SUCH_ROOM, "that room publication is no longer current");
			return entry.kind === "local"
				? session.spawn(roomBehavior(entry.state))
				: entry.kind === "bridge"
				? session.spawn(entry.bridge.roomBehavior())
				: entry.room;
		}
		if (verb === LIST) {
			if (args.length !== 0) throw new Error("list takes no arguments");
			return roomSnapshot("baseline").rows;
		}
		if (verb === LIST_PUBLICATIONS) {
			if (args.length !== 0) throw new Error("listPublications takes no arguments");
			return roomSnapshot("publication").rows;
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
			dropWatchers(session);
			let admitted = false;
			try {
				watchers.push({
					observer,
					session,
					records: verb === WATCH_PUBLICATIONS ? "publication" : "baseline",
				});
				admitted = true;
				return verb === WATCH_PUBLICATIONS
					? directoryWatchSnapshot("publication")
					: roomSnapshot("baseline").rows;
			} catch (error) {
				if (admitted) dropWatchers(session);
				else handBack(session, observer, "refused directory watcher");
				throw error;
			}
		}
		throw new Error(`directory has no method ${verb}`);
	};
}

/** What the inspect capability can currently see of this directory.
 *
 * Rows are `[kind, name, note]`. Live room references are not handed out here:
 * holding inspect is the right to *see* what the directory holds, and entering
 * a room is still `enter` / `open` on the directory the caller already fetched.
 * Durable room links are listed by the swiss they answer to, which is the OCapN
 * name.
 *
 * This is the Rooms operator's own view, so it shows every room including
 * private ones, by label and with their occupants. That is not the leak a
 * private room is protected from: privacy here is being absent from the
 * user-facing `list` and `watch`, unreachable except through a reference
 * somebody handed you. The operator, who holds the `--diagnostics` swiss and
 * runs the process, is the one principal that view was never hiding from. */
function diagnosticSnapshot(): Argument[] {
	const rows: Argument[] = [[
		"directory",
		DIRECTORY,
		"published bootstrap",
	]];
	for (const state of rooms.values()) {
		const place = state.private ? "private" : "public";
		rows.push([
			"room",
			state.name,
			`${place}, ${state.members.length} here`,
		]);
		for (const member of state.members) {
			rows.push(["occupant", member.nick, `in ${state.name}`]);
		}
	}
	for (const intro of introductions.values()) {
		rows.push([
			"registration",
			intro.nick,
			`${intro.inboxes.size} inboxes offered`,
		]);
	}
	const links = heldRoomLinks();
	if (links !== null) {
		for (const { name } of links.named()) {
			// Inspect observes that the durable publication exists. Its swiss is
			// bearer authority to enter the room and belongs only on a separately
			// granted recovery/control surface.
			rows.push(["link", name, "durable publication active"]);
		}
	}
	// The server's own trouble journal rides the same snapshot, so an operator
	// holding inspect reads what went wrong beside what the directory holds.
	for (const entry of troubleRows()) {
		rows.push([
			"trouble",
			entry.source,
			entry.count > 1 ? `${entry.reason} ×${entry.count}` : entry.reason,
		]);
	}
	return rows;
}

export function inspectBehavior(): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const session = currentSession();
		if (session == null) throw new Error("diagnostics is reachable only over a session");
		if (hasCapabilityArguments(args)) {
			refuseDirectoryCall(session, args, new Error(`diagnostics ${verb} does not take capability arguments`));
		}
		if (verb === SNAPSHOT) {
			if (args.length !== 0) throw new Error("snapshot takes no arguments");
			return diagnosticSnapshot();
		}
		throw new Error(`diagnostics has no method ${verb}`);
	};
}
