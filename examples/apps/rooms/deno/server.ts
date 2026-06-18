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
// the default `tcp` listens on `127.0.0.1:<port>`; `iroh` binds an encrypted-QUIC
// endpoint and announces an `ocapn://<nodeid>.iroh?direct-addresses=…` URI.
// Either way the announce line is `ROOMS-SERVER-LISTENING <locator>`, which the
// demo harness and web bridge read to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read server.ts 9099
//          ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts

import { type AppValue, Connection, listen, Machine, Ref } from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
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
	WATCH,
} from "./protocol.ts";

/** One subscriber: the nickname it chose and the capability to call it back on,
 * plus the connection that capability lives on (a far ref is sent over the
 * connection that holds it). */
interface Member {
	nick: string;
	inbox: Ref;
	conn: Connection;
}

/** A live room: its display name (the casing the opener chose), its roster, and
 * the connection that opened it. The room owns its members and its broadcast;
 * the directory owns the set of rooms. A room lives while it has members; an
 * `open`ed room with no members yet is reclaimed if its opener disconnects
 * before subscribing. */
interface RoomState {
	name: string;
	members: Member[];
	creator: Connection;
}

const rooms = new Map<string, RoomState>();

/** Introducible members, by nick: the `dm` reference the directory fetched from
 * each member's own endpoint. Each reference's `home` is the directory↔member
 * connection the directory dialed, so returning one from `introduce` trips the
 * binding's transparent gifter — the directory deposits the gift with the member
 * and answers the caller with a `desc:handoff-give`, never relaying the DM. */
const introductions = new Map<string, Ref>();

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
	machine: Machine,
	nick: string,
	locator: string,
	inbox: Ref,
	conn: Connection,
): Promise<void> {
	const key = nickKey(nick);
	if (registering.has(key) || introductions.has(key)) return;
	registering.add(key);
	try {
		// Dial the member with the node's shared identity so the gift the directory
		// later mints (signed with that identity) matches the deposit's provenance.
		const toMember = await Connection.connect(
			locator.slice(0, locator.lastIndexOf(":")),
			Number(locator.slice(locator.lastIndexOf(":") + 1)),
			machine,
		);
		toMember.serve().catch(() => {});
		const dm = await toMember.fetch("dm");
		introductions.set(key, dm);
		// Deterministic readiness: the member learns its nick is introducible only
		// once the dial-back has the `dm` in hand.
		conn.tell(inbox, NOTIFY, ["registered", nick]).catch(() => {});
	} finally {
		registering.delete(key);
	}
}

/** Directory-wide observers of the live room list. A `watch` registers its inbox
 * capability here; every membership transition pushes a delta to each one. They
 * are global because they watch the whole directory, not one room. */
const watchers: { observer: Ref; conn: Connection }[] = [];

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

function dropWatchers(conn: Connection): void {
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

function findByConn(state: RoomState, conn: Connection): Member | null {
	return state.members.find((m) => m.conn === conn) ?? null;
}

function claimedByAnother(
	state: RoomState,
	conn: Connection,
	nick: string,
): boolean {
	const key = nickKey(nick);
	return state.members.some((m) => m.conn !== conn && nickKey(m.nick) === key);
}

/** Push `from: text` to every subscriber of `state` by calling the inbox
 * capability it gave us. `tell` is the fire-and-forget eventual-send: a notify
 * wants no reply, so it costs one deliver with no answer round-trip. A member
 * whose socket has died is dropped from every room it joined. */
function broadcast(state: RoomState, from: string, text: string): void {
	for (const m of [...state.members]) {
		m.conn.tell(m.inbox, NOTIFY, [from, text]).catch(() => leaveAll(m.conn));
	}
}

/** Remove `conn`'s membership from one room, announcing its departure, and
 * delete the room if that emptied it. The `silent` path is for resubscribe,
 * which drops the prior membership and immediately adds a new one, so it must
 * neither announce a spurious leave nor garbage-collect a room it is about to
 * reuse. */
function leaveRoom(
	state: RoomState,
	conn: Connection,
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

/** Drop a connection from every room it is in — the cleanup when its socket
 * closes. Also reclaim any room this connection opened but never subscribed to,
 * so an abandoned `open` does not leak an empty room. */
function leaveAll(conn: Connection): void {
	for (const state of [...rooms.values()]) {
		leaveRoom(state, conn);
		if (state.members.length === 0 && state.creator === conn) {
			rooms.delete(roomKey(state.name));
		}
	}
	dropWatchers(conn);
}

/** The room behavior for one connection. The room grants at most one live
 * membership to the connection, so `post` needs no "from" argument — the
 * capability the post arrives on is the authority to speak in this room. */
function roomBehavior(state: RoomState, conn: Connection) {
	return (verb: string, args: AppValue[]): AppValue => {
		if (verb === SUBSCRIBE) {
			const nick = typeof args[0] === "string" ? args[0] : "anon";
			const inbox = args[1];
			if (!(inbox instanceof Ref)) {
				throw new Error("subscribe needs an inbox capability");
			}
			if (claimedByAnother(state, conn, nick)) {
				throw new Error(`name "${nick}" is already claimed`);
			}
			// A resubscribe (same connection re-claiming) nets no count change, so it
			// must not fire a discovery event; a fresh membership does.
			const wasMember = findByConn(state, conn) !== null;
			if (wasMember) leaveRoom(state, conn, true);
			state.members.push({ nick, inbox, conn });
			broadcast(state, "room", `${nick} joined (${state.members.length} here)`);
			if (!wasMember) {
				notifyWatchers(
					state.members.length === 1 ? "opened" : "count",
					state.name,
					state.members.length,
				);
			}
			// The welcome names everyone present: join announcements only reach
			// members already in the room, so this list is how a late joiner learns
			// who arrived before it.
			return `welcome ${nick} — ${state.members.length} in the room: ${
				state.members.map((m) => m.nick).join(", ")
			}`;
		}
		if (verb === POST) {
			const member = findByConn(state, conn);
			if (member === null) {
				throw new Error("post needs a claimed room membership");
			}
			broadcast(state, member.nick, typeof args[0] === "string" ? args[0] : "");
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
 * a client holds is bound to that client's connection. `machine` is the node's
 * shared identity/gift registry, needed to dial members back for introductions. */
export function directoryBehavior(conn: Connection, machine: Machine) {
	return (verb: string, args: AppValue[]): AppValue => {
		if (verb === REGISTER) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const locator = typeof args[1] === "string" ? args[1] : "";
			const inbox = args[2];
			if (nick.length === 0 || locator.length === 0) {
				throw new Error("register needs a nick and a host:port locator");
			}
			if (!(inbox instanceof Ref)) {
				throw new Error("register needs an inbox capability");
			}
			if (locator.lastIndexOf(":") < 0) {
				throw new Error("register locator must be host:port");
			}
			// The dial-back is async; kick it off and ack now. The member waits for
			// the `notify("registered", …)` the dial-back pushes before treating its
			// nick as introducible, so there is no register/introduce race.
			void registerMember(machine, nick, locator, inbox, conn);
			return null;
		}
		if (verb === INTRODUCE) {
			const nick = typeof args[0] === "string" ? args[0] : "";
			const dm = introductions.get(nickKey(nick));
			if (dm === undefined) {
				throw new Error(`no member named "${nick}" is registered`);
			}
			// Returning a reference whose home is the directory↔member connection
			// trips the transparent gifter: the caller gets a give, not a relay.
			return dm;
		}
		const name = typeof args[0] === "string" ? args[0] : "";
		if (verb === OPEN) {
			if (name.length === 0) throw new Error("open needs a room name");
			if (rooms.has(roomKey(name))) {
				throw new Error(`room "${name}" already exists`);
			}
			const state: RoomState = { name, members: [], creator: conn };
			rooms.set(roomKey(name), state);
			return conn.spawn(roomBehavior(state, conn));
		}
		if (verb === ENTER) {
			const state = rooms.get(roomKey(name));
			if (state === undefined) throw new Error(`no room named "${name}"`);
			return conn.spawn(roomBehavior(state, conn));
		}
		if (verb === LIST) return snapshot();
		if (verb === WATCH) {
			const observer = args[0];
			if (!(observer instanceof Ref)) {
				throw new Error("watch needs an inbox capability");
			}
			watchers.push({ observer, conn });
			return snapshot(); // a baseline; deltas follow on the inbox
		}
		throw new Error(`directory has no method ${verb}`);
	};
}

function transportArg(): "tcp" | "iroh" {
	const flag = Deno.args.find((a) => a.startsWith("--transport="));
	// ROOMS_TRANSPORT is a convenience for manual runs; only read it when env
	// access is granted so the default (TCP) permission set never trips.
	const envAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_TRANSPORT" })
		.state === "granted";
	const choice =
		(flag
			? flag.slice("--transport=".length)
			: (envAllowed ? Deno.env.get("ROOMS_TRANSPORT") : undefined)) ?? "tcp";
	if (choice !== "tcp" && choice !== "iroh") {
		console.error(
			`server.ts: unknown transport "${choice}" (expected tcp or iroh)`,
		);
		Deno.exit(2);
	}
	return choice;
}

/** Serve the directory on every connection `server` accepts until it closes.
 * `machine` is the node's shared identity/gift registry — the same one the
 * accepted connections key with — so `register`'s dial-back and `introduce`'s
 * gift origination share one identity (the directory↔member dial and the
 * directory↔caller answer must agree for the handoff signature to verify). */
export async function serveDirectory(
	server: AsyncIterable<Connection>,
	machine: Machine,
): Promise<void> {
	for await (const conn of server) {
		conn.publish(DIRECTORY, directoryBehavior(conn, machine)); // fetchable by name
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
		// The rooms URIs carry direct-addresses, so `.direct` is the explicit posture.
		// Introductions (`register`/`introduce`) are TCP-only this cycle, so the iroh
		// room serves chat with a fresh node identity for the directory dial-back.
		const iroh = listenIroh(Reachability.Direct);
		console.log(`ROOMS-SERVER-LISTENING ${iroh.uri}`);
		await serveDirectory(iroh, new Machine());
	} else {
		const tcp = listen("127.0.0.1", Number(positional[0] ?? "0"));
		console.log(`ROOMS-SERVER-LISTENING ${await tcp.ready()}`);
		await serveDirectory(tcp, tcp.machine);
	}
}
