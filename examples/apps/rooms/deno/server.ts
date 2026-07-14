// The rooms chat server, written on pancake actors in native Deno.
//
// It hosts a *directory* of chat rooms and accepts any number of OCapN clients —
// in any language, over either transport. A client fetches the directory, then
// `open`s a new room or `enter`s an existing one; either call returns a live
// reference to that room. The client subscribes to the room with a nickname and
// a capability to its own inbox; the room keeps every subscriber's inbox
// capability and, when anyone posts, calls each one back with `notify`. The
// clients never poll: the room pushes to them because it holds a live capability
// to each.
//
// The directory is the server's one published bootstrap object; rooms are the
// references it hands back. A room exists only while someone is in it — when its
// last member leaves, the room is removed and its name frees up. The directory
// also answers `list` (the live rooms, as `[name, count]` pairs) and `watch`
// (hand it an inbox; it pushes a `notify(event, name, count)` delta on every
// open/close/count change), so a client can discover and follow rooms, not just
// open and enter them.
//
// `publish` makes the directory fetchable by name; the directory and room
// behaviors are plain functions of `(verb, args)`; a subscriber's inbox arrives
// as a `Ref` the room sends to. No peer, no vat, no manual flush, no hand-rolled
// serve loop — the capability model is the whole program.
//
// Transport is chosen by the `ROOMS_TRANSPORT` env var (or `--transport=iroh`):
// the default `tcp` listens on `127.0.0.1:<port>` (override with `ROOMS_BIND`);
// `iroh` binds an encrypted-QUIC endpoint. `ROOMS_REACHABILITY=discovery` puts the
// iroh endpoint on n0 relays + DNS/pkarr and announces a bare
// `ocapn://<nodeid>.iroh` URI (dial-by-id); the default `direct` announces
// `ocapn://…?direct-addresses=…` for hermetic same-host demos. On TCP,
// `ROOMS_ANNOUNCE_HOST` (when set) is the dialable hostname printed and used as
// the self-designator. Either way the announce line is
// `ROOMS-SERVER-LISTENING <locator>`, which the demo harness and web bridge read
// to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read --allow-env server.ts 9099
//          ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts
//          ROOMS_TRANSPORT=iroh ROOMS_REACHABILITY=discovery deno run -A --unstable-ffi server.ts

import {
	type AppValue,
	designatorHostPort,
	encodePeerLocator,
	formatPeerUri,
	HINT_DIRECT_ADDRESSES,
	Host,
	listen,
	parseLocator,
	Ref,
	type Session,
	socketAddrDesignator,
	TRANSPORT_IROH,
} from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { dial, isUriLocator } from "./lib/locator.ts";
import { NICK_TAKEN, NO_SUCH_ROOM, PEER_OFFLINE, ROOM_EXISTS, RoomError } from "./lib/errors.ts";
import {
	DIRECTORY,
	ENTER,
	INTRODUCE,
	LEAVE,
	LIST,
	NOTIFY,
	OPEN,
	POST,
	REGISTER,
	SUBSCRIBE,
	TYPING,
	WATCH,
} from "./lib/protocol.ts";

/** One subscriber: the nickname it chose and the capability to call it back on,
 * plus the connection that capability lives on (a far ref is sent over the
 * connection that holds it). */
interface Member {
	nick: string;
	inbox: Ref;
	conn: Session;
}

/** A live room: its display name (the casing the opener chose), its roster, and
 * the connection that opened it. The room owns its members and its broadcast;
 * the directory owns the set of rooms. A room lives while it has members; an
 * `open`ed room with no members yet is reclaimed if its opener disconnects
 * before subscribing. */
interface RoomState {
	name: string;
	members: Member[];
	creator: Session;
}

const rooms = new Map<string, RoomState>();

/** One introducible member. `dm` is the reference the directory fetched from the
 * member's own endpoint, `toMember` is the directory↔member connection that
 * reference lives on, and `registrar` is the caller connection whose `register`
 * created the whole thing. Because `dm`'s home is `toMember`, returning it from
 * `introduce` trips the binding's transparent gifter: the directory deposits the
 * gift with the member and answers the caller with a `desc:handoff-give`, rather
 * than relaying the DM itself. `registrar` is how a disconnect cleans this up.
 * When the member's own session to the directory ends, the directory withdraws
 * the introduction and closes `toMember`. */
interface Introduction {
	nick: string;
	dm: Ref;
	toMember: Session;
	registrar: Session;
}

/** Introducible members, by nick. */
const introductions = new Map<string, Introduction>();

/** Members whose dial-back is in flight, so a second `register` for the same
 * nick (a reconnect) does not start a duplicate dial. */
const registering = new Set<string>();

/** Dial a member back at its own locator, fetch its exported `dm` object, and
 * hold the reference under `nick` so `introduce` can hand it on. The dial-back
 * is what makes the member the *exporter* in the eventual handoff: the gift the
 * directory mints names this member's locator, and the introduced caller dials
 * it directly. On success the member's inbox is told `notify("registered",
 * nick)`, the deterministic signal that the nick is now introducible. */
async function registerMember(
	host: Host,
	nick: string,
	locator: string,
	inbox: Ref,
	conn: Session,
): Promise<void> {
	const key = nickKey(nick);
	if (registering.has(key) || introductions.has(key)) return;
	registering.add(key);
	try {
		// Dial the member with the host's shared identity so the gift the directory
		// later mints (signed with that identity) matches the deposit's provenance.
		// Transport-neutral: a `hostname:port` dials TCP; an `ocapn://…iroh` URI dials
		// iroh's encrypted QUIC — by direct-address hints when the URI carries them,
		// else by resolving the node id through discovery (see `dial`).
		const toMember = await dial(locator, host);
		toMember.serve().catch(() => {});
		// An iroh member signs only its node id on its session, so the gift's
		// exporter location would otherwise carry no way to reach it. Re-encode the
		// member's registered locator as the gift's exporter location, so the gift
		// names the member exactly as the member advertised — id + direct-addresses
		// for a direct member, id alone for a discovery member — and the recipient's
		// redeem picks the dial posture from those hints. A TCP member's signed
		// host:port is already dialable, so it keeps the partner's signed location.
		if (isUriLocator(locator)) {
			const loc = parseLocator(locator);
			toMember.setExporterLocator(encodePeerLocator({
				transport: loc.transport,
				designator: loc.designator,
				directAddresses: loc.hints.get(HINT_DIRECT_ADDRESSES) ?? "",
			}));
		}
		const dm = await toMember.fetch("dm");
		introductions.set(key, { nick, dm, toMember, registrar: conn });
		// Deterministic readiness: the member learns its nick is introducible only
		// once the dial-back has the `dm` in hand.
		conn.tell(inbox, NOTIFY, ["registered", nick]).catch(() => {});
		// Tell every directory watcher this nick is now reachable for direct
		// messages, so a UI can offer to introduce people to it.
		notifyWatchers("registered", nick, 1);
	} finally {
		registering.delete(key);
	}
}

/** Withdraw every introduction a closing connection registered: drop the nick so
 * `introduce` stops handing out a stale gift, close the directory's own dial-back
 * to that member, and tell the watchers the nick is gone. */
function dropIntroductions(conn: Session): void {
	for (const [key, intro] of [...introductions]) {
		if (intro.registrar !== conn) continue;
		introductions.delete(key);
		try {
			intro.toMember.close();
		} catch { /* already closed */ }
		notifyWatchers("unregistered", intro.nick, 0);
	}
}

/** Directory-wide observers of the live room list. A `watch` registers its inbox
 * capability here; every membership transition pushes a delta to each one. They
 * are global because they watch the whole directory, not one room. */
const watchers: { observer: Ref; conn: Session }[] = [];

/** The live rooms — those with at least one member — as `[name, count]` pairs.
 * A just-`open`ed room with no members yet is invisible until its first
 * subscriber, so discovery only ever shows rooms with people in them. Counts go
 * over the wire as `bigint`, the integer type (a plain `number` is a float). */
function snapshot(): AppValue[] {
	const live: AppValue[] = [];
	for (const state of rooms.values()) {
		if (state.members.length > 0) {
			live.push([state.name, BigInt(state.members.length)]);
		}
	}
	return live;
}

/** Push one room-list delta to every watcher: `notify(event, name, count)` with
 * `event` one of `opened` / `closed` / `count`. A watcher whose inbox can no
 * longer be reached (its connection died) is dropped. */
function notifyWatchers(event: string, name: string, count: number): void {
	for (const w of [...watchers]) {
		w.conn.tell(w.observer, NOTIFY, [event, name, BigInt(count)]).catch(() => {
			const i = watchers.indexOf(w);
			if (i >= 0) watchers.splice(i, 1);
		});
	}
}

function dropWatchers(conn: Session): void {
	for (let i = watchers.length - 1; i >= 0; i -= 1) {
		if (watchers[i].conn === conn) watchers.splice(i, 1);
	}
}

/** Room names are unique ignoring case, like nicknames: the directory grants one
 * room per name and frees it when the room empties. */
function roomKey(name: string): string {
	return name.toLowerCase();
}

function nickKey(nick: string): string {
	return nick.toLowerCase();
}

function findByConn(state: RoomState, conn: Session): Member | null {
	return state.members.find((m) => m.conn === conn) ?? null;
}

function claimedByAnother(
	state: RoomState,
	conn: Session,
	nick: string,
): boolean {
	const key = nickKey(nick);
	return state.members.some((m) => m.conn !== conn && nickKey(m.nick) === key);
}

/** Push `from: text` to every subscriber of `state` by calling the inbox
 * capability it gave us. `tell` is the fire-and-forget eventual-send: a notify
 * wants no reply, so it costs one deliver with no answer round-trip. A member
 * whose socket has died is dropped from every room it joined. */
function broadcast(
	state: RoomState,
	from: string,
	text: string,
	...presence: string[]
): void {
	// A presence line carries structured trailing args after the display text — a
	// join/leave kind and the nick — so a member reads the change without parsing the
	// prose. A chat line passes none.
	for (const m of [...state.members]) {
		m.conn.tell(m.inbox, NOTIFY, [from, text, ...presence]).catch(() => leaveAll(m.conn));
	}
}

/** Push an ephemeral typing flag to every *other* member of `state`. Typing is
 * best-effort presence, not a line: it carries no text, is never stored, and is
 * never echoed to the typer (`exceptConn`). It rides the same `notify` inbox as
 * a room line, tagged `"typing"` at the third argument so any subscriber that
 * does not care skips it. A member whose socket has died is dropped. */
function broadcastTyping(
	state: RoomState,
	nick: string,
	on: boolean,
	exceptConn: Session,
): void {
	for (const m of [...state.members]) {
		if (m.conn === exceptConn) continue;
		m.conn.tell(m.inbox, NOTIFY, ["room", "", "typing", nick, on]).catch(() =>
			leaveAll(m.conn)
		);
	}
}

/** Remove `conn`'s membership from one room, announcing its departure, and
 * delete the room if that emptied it. The `silent` path is for resubscribe,
 * which drops the prior membership and immediately adds a new one, so it must
 * neither announce a spurious leave nor garbage-collect a room it is about to
 * reuse. */
function leaveRoom(
	state: RoomState,
	conn: Session,
	silent = false,
): boolean {
	let removed = false;
	for (let i = state.members.length - 1; i >= 0; i -= 1) {
		if (state.members[i].conn === conn) {
			const member = state.members[i];
			state.members.splice(i, 1);
			removed = true;
			if (!silent) {
				broadcast(
					state,
					"room",
					`${member.nick} left (${state.members.length} here)`,
					"leave",
					member.nick,
				);
			}
		}
	}
	if (!silent && removed && state.members.length === 0) {
		rooms.delete(roomKey(state.name));
	}
	// A real departure changes the live room list: the room closed if it emptied,
	// else its count dropped. A silent resubscribe leaves the count unchanged.
	if (!silent && removed) {
		if (state.members.length === 0) notifyWatchers("closed", state.name, 0);
		else notifyWatchers("count", state.name, state.members.length);
	}
	return removed;
}

/** Drop a session from every room it is in, the cleanup when its socket
 * closes. Also reclaim any room this session opened but never subscribed to,
 * so an abandoned `open` does not leak an empty room. */
function leaveAll(conn: Session): void {
	for (const state of [...rooms.values()]) {
		leaveRoom(state, conn);
		if (state.members.length === 0 && state.creator === conn) {
			rooms.delete(roomKey(state.name));
		}
	}
	dropWatchers(conn);
	dropIntroductions(conn);
}

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak in this room. */
function roomBehavior(state: RoomState, conn: Session) {
	return (verb: string, args: AppValue[]): AppValue => {
		if (verb === SUBSCRIBE) {
			const nick = typeof args[0] === "string" ? args[0] : "anon";
			const inbox = args[1];
			if (!(inbox instanceof Ref)) {
				throw new Error("subscribe needs an inbox capability");
			}
			if (claimedByAnother(state, conn, nick)) {
				throw new RoomError(NICK_TAKEN, `name "${nick}" is already claimed`);
			}
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const wasMember = findByConn(state, conn) !== null;
			if (wasMember) leaveRoom(state, conn, true);
			state.members.push({ nick, inbox, conn });
			broadcast(state, "room", `${nick} joined (${state.members.length} here)`, "join", nick);
			if (!wasMember) {
				notifyWatchers(
					state.members.length === 1 ? "opened" : "count",
					state.name,
					state.members.length,
				);
			}
			// The new member's welcome names everyone present and carries the roster as
			// structured trailing args ("roster" then each nick), so it learns who
			// arrived before it without parsing the text. It goes to the new member
			// alone; `subscribe` itself returns a bare ack — success is the resolution, a
			// claimed nick is the rejection above.
			const names = state.members.map((m) => m.nick);
			conn.tell(inbox, NOTIFY, [
				"room",
				`welcome ${nick} — ${names.length} in the room: ${names.join(", ")}`,
				"roster",
				...names,
			]).catch(() => leaveAll(conn));
			return null;
		}
		if (verb === POST) {
			const member = findByConn(state, conn);
			if (member === null) {
				throw new Error("post needs a claimed room membership");
			}
			broadcast(state, member.nick, typeof args[0] === "string" ? args[0] : "");
			return null;
		}
		if (verb === TYPING) {
			// Ephemeral: only a claimed member can signal, and the signal reaches the
			// other members alone. An un-subscribed connection is a silent no-op — a
			// stale typing flag is never worth an error.
			const member = findByConn(state, conn);
			if (member !== null) broadcastTyping(state, member.nick, args[0] === true, conn);
			return null;
		}
		if (verb === LEAVE) {
			// Drop just this membership, keeping the connection open so the client can
			// enter another room. Idempotent: leaving a room you are not in is a no-op.
			leaveRoom(state, conn);
			return null;
		}
		throw new Error(`room has no method ${verb}`);
	};
}

/** The directory behavior for one connection. `open`/`enter` return a live
 * reference to a room — the per-connection room view spawned here — so the room
 * a client holds is bound to that client's connection. `host` is the host's
 * shared identity/gift registry, needed to dial members back for introductions. */
export function directoryBehavior(conn: Session, host: Host) {
	return (verb: string, args: AppValue[]): AppValue => {
		if (verb === REGISTER) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const locator = typeof args[1] === "string" ? args[1] : "";
			const inbox = args[2];
			if (nick.length === 0 || locator.length === 0) {
				throw new Error("register needs a nick and a locator");
			}
			if (!(inbox instanceof Ref)) {
				throw new Error("register needs an inbox capability");
			}
			// A locator is either a TCP `hostname:port` or an `ocapn://…iroh?…` URI; both
			// have a colon, so just require one that the dial-back can parse.
			if (!isUriLocator(locator)) {
				try {
					designatorHostPort(locator);
				} catch {
					throw new Error("register locator must be hostname:port or an ocapn:// URI");
				}
			}
			// The dial-back is async; kick it off and ack now. The member waits for
			// the `notify("registered", …)` the dial-back pushes before treating its
			// nick as introducible, so there is no register/introduce race.
			void registerMember(host, nick, locator, inbox, conn);
			return null;
		}
		if (verb === INTRODUCE) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const intro = introductions.get(nickKey(nick));
			if (intro === undefined) {
				throw new RoomError(PEER_OFFLINE, `no member named "${nick}" is registered`);
			}
			// Returning a reference whose home is the directory↔member connection
			// trips the transparent gifter: the caller gets a give, not a relay.
			return intro.dm;
		}
		const name = typeof args[0] === "string" ? args[0] : "";
		if (verb === OPEN) {
			if (name.length === 0) throw new Error("open needs a room name");
			if (rooms.has(roomKey(name))) {
				throw new RoomError(ROOM_EXISTS, `room "${name}" already exists`);
			}
			const state: RoomState = { name, members: [], creator: conn };
			rooms.set(roomKey(name), state);
			return conn.spawn(roomBehavior(state, conn));
		}
		if (verb === ENTER) {
			const state = rooms.get(roomKey(name));
			if (state === undefined) throw new RoomError(NO_SUCH_ROOM, `no room named "${name}"`);
			return conn.spawn(roomBehavior(state, conn));
		}
		if (verb === LIST) return snapshot();
		if (verb === WATCH) {
			const observer = args[0];
			if (!(observer instanceof Ref)) {
				throw new Error("watch needs an inbox capability");
			}
			watchers.push({ observer, conn });
			// Replay the members already introducible for direct messages, so a
			// fresh watcher (a browser tab, say) starts with the same DM-able set
			// everyone else already knows. The room-list baseline is the return
			// value; these arrive as ordinary deltas on the inbox.
			for (const intro of introductions.values()) {
				conn.tell(observer, NOTIFY, ["registered", intro.nick, 1n]).catch(() => {});
			}
			return snapshot(); // a baseline; deltas follow on the inbox
		}
		throw new Error(`directory has no method ${verb}`);
	};
}

/** Read an optional env var when permission is granted; otherwise undefined. */
function optionalEnv(name: string): string | undefined {
	const allowed = Deno.permissions.querySync({ name: "env", variable: name }).state ===
		"granted";
	if (!allowed) return undefined;
	const value = Deno.env.get(name)?.trim();
	return value && value.length > 0 ? value : undefined;
}

function transportArg(): "tcp" | "iroh" {
	const flag = Deno.args.find((a) => a.startsWith("--transport="));
	// ROOMS_TRANSPORT is a convenience for manual runs; only read it when env
	// access is granted so the default (TCP) permission set never trips.
	const choice = (flag ? flag.slice("--transport=".length) : optionalEnv("ROOMS_TRANSPORT")) ??
		"tcp";
	if (choice !== "tcp" && choice !== "iroh") {
		console.error(
			`server.ts: unknown transport "${choice}" (expected tcp or iroh)`,
		);
		Deno.exit(2);
	}
	return choice;
}

/** iroh dial posture: `direct` (default, hermetic) or `discovery` (n0 + pkarr). */
function reachabilityArg(): typeof Reachability.Direct | typeof Reachability.Discovery {
	const choice = (optionalEnv("ROOMS_REACHABILITY") ?? "direct").toLowerCase();
	if (choice === "discovery") return Reachability.Discovery;
	if (choice === "direct") return Reachability.Direct;
	console.error(
		`server.ts: unknown reachability "${choice}" (expected direct or discovery)`,
	);
	Deno.exit(2);
}

/** Serve the directory on every connection `server` accepts until it closes.
 * `host` is the host's shared identity/gift registry — the same one the
 * accepted connections key with — so `register`'s dial-back and `introduce`'s
 * gift origination share one identity (the directory↔member dial and the
 * directory↔caller answer must agree for the handoff signature to verify). */
export async function serveDirectory(
	server: AsyncIterable<Session>,
	host: Host,
): Promise<void> {
	for await (const conn of server) {
		conn.publish(DIRECTORY, directoryBehavior(conn, host)); // fetchable by name
		conn.serve().then(
			() => leaveAll(conn),
			() => leaveAll(conn),
		);
	}
}

// The top-level bootstrap runs only when this file is the program, so the demo
// orchestrator (and tests) can import the behaviors without binding a socket.
if (import.meta.main) {
	// Positional args are the port (TCP only); iroh has no port to pin.
	const positional = Deno.args.filter((a) => !a.startsWith("--"));
	const transport = transportArg();

	// The harness and the web bridge parse the announce line: a bare port is a TCP
	// locator (127.0.0.1:<port>), an ocapn:// URI is an iroh locator.
	if (transport === "iroh") {
		// One shared host across the iroh listener and the directory behavior, so
		// `register`'s dial-back and `introduce`'s gift origination present one
		// identity, what a cross-process three-party handoff over iroh requires.
		// One seed for the host identity AND the endpoint, so every accepted
		// session signs with the endpoint's own key: iroh's designator is that
		// key, and a dialer that pins the session identity to the node id it
		// dialed (the Zig rooms client) verifies exactly this.
		const seed = crypto.getRandomValues(new Uint8Array(32));
		const host = new Host(seed);
		const reach = reachabilityArg();
		const iroh = listenIroh(reach, seed, host);
		// Discovery: announce node id alone so partners resolve via n0/pkarr.
		// Direct: announce with direct-address hints for same-host hermetic demos.
		const announce = reach === Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, iroh.nodeId)
			: iroh.uri;
		console.log(`ROOMS-SERVER-LISTENING ${announce}`);
		await serveDirectory(iroh, host);
	} else {
		// Default loopback keeps local demos hermetic. Optional ROOMS_BIND /
		// ROOMS_ANNOUNCE_HOST publish a TCP directory on a shared network when
		// not using iroh.
		const bindHost = optionalEnv("ROOMS_BIND") ?? "127.0.0.1";
		const announceHost = optionalEnv("ROOMS_ANNOUNCE_HOST");
		const tcp = listen(bindHost, Number(positional[0] ?? "0"));
		const boundPort = await tcp.ready();
		if (announceHost) {
			const designator = socketAddrDesignator(announceHost, boundPort);
			tcp.host.setSelfDesignator(designator);
			console.log(`ROOMS-SERVER-LISTENING ${designator}`);
		} else {
			console.log(`ROOMS-SERVER-LISTENING ${boundPort}`);
		}
		await serveDirectory(tcp, tcp.host);
	}
}
