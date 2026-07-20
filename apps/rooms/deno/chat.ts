// An interactive rooms chat client, in Deno, the one you actually talk in.
//
// It enters a room, prints every line as it arrives, and posts whatever you
// type. Lines that start with "/" are commands, not chat:
//
//   /list            the rooms with people in them, right now
//   /open <name>     open a new room and move into it
//   /enter <name>    move into an existing room
//   /leave           leave the current room (stay connected)
//   /help            this list
//
// All the OCapN machinery lives in `room_client.ts` (`Directory`, `Room`): one
// connection holds the directory, a live room-list `watch`, and your current
// membership; switching rooms leaves one and enters another on that same
// connection. Press Ctrl-D to quit.
//
//   deno run --allow-ffi --allow-read --allow-net chat.ts 127.0.0.1:9099 general alice
//
// The locator is transport-neutral: a `host:port` joins over TCP, an
// `ocapn://<nodeid>.iroh?direct-addresses=…` URI joins over iroh (the room
// prints it as its `ROOMS-SERVER-LISTENING` line in iroh mode). iroh dialing
// needs `--unstable-ffi`. The room you start in is named: entering one that does
// not exist yet opens it.

import { Directory, Room } from "../lib/room_client.ts";
import { enterOrOpen } from "./lib/enter_room.ts";
import { type Ref } from "@pancake/stack";
import { dial } from "./lib/locator.ts";

const [locator, room_name, nick] = Deno.args;
if (!locator || !room_name || !nick) {
	console.error(
		"usage: chat.ts <locator> <room> <nick>   (locator: host:port or an ocapn:// URI)",
	);
	Deno.exit(2);
}

const dir = await Directory.connect(locator, dial);

// Follow the directory so `/list` is always current: fold each delta into a map
// of live rooms, seeded with the snapshot `watch` returns.
const liveRooms = new Map<string, number>();
for (
	const room of await dir.watch((event) => {
		if (event.kind === "closed") liveRooms.delete(event.name);
		else liveRooms.set(event.name, event.count);
	})
) liveRooms.set(room.name, room.count);

// The single membership we are currently in, held in an object so it reads as
// `Room | null` everywhere (a bare `let` would narrow to `null` across the
// closures that reassign it).
const session: { room: Room | null } = { room: null };

// The room we start in: enter it, opening it if it does not exist yet (the
// friendly default; `/open` and `/enter` below are the strict, explicit verbs).
await showRoom(await enterOrOpen(dir, room_name), room_name);
console.log("(type a line to talk, /help for commands, Ctrl-D to quit)");

for await (const line of typedLines()) await handle(line);

await session.room?.leave();
await dir.close();

// Subscribe to a room and make it the one we show and talk in. Subscribe before
// leaving the old one, so a rejected claim (the nickname is taken there) leaves
// the current room untouched.
async function showRoom(roomRef: Ref, name: string): Promise<void> {
	const next = await Room.subscribe(dir.session, roomRef, nick);
	await session.room?.leave();
	session.room = next;
	console.log(`(in "${name}" as "${nick}")`);
	pump(next);
}

// Print each line a room sends until it ends (we left, or it hung up). One pump
// runs per room; leaving a room ends its stream and so ends its pump.
async function pump(room: Room): Promise<void> {
	try {
		for await (const { from, text, system } of room.messages) {
			console.log(system ? `* ${text}` : `${from}: ${text}`);
		}
	} catch { /* the stream ended under us, nothing to show */ }
}

// A typed line is a command if it starts with "/"; otherwise it is chat.
async function handle(line: string): Promise<void> {
	if (line.length === 0) return;
	if (!line.startsWith("/")) {
		if (session.room) await session.room.say(line);
		else console.log("* not in a room — /enter or /open one first");
		return;
	}
	const [cmd, ...rest] = line.slice(1).split(/\s+/);
	const name = rest.join(" ").trim();
	switch (cmd) {
		case "list":
			showRooms();
			break;
		case "open":
			if (!name) return void console.log("* usage: /open <name>");
			await tryMove(() => dir.open(name), name, "open");
			break;
		case "enter":
			if (!name) return void console.log("* usage: /enter <name>");
			await tryMove(() => dir.enter(name), name, "enter");
			break;
		case "leave":
			if (!session.room) return void console.log("* not in a room");
			await session.room.leave();
			session.room = null;
			console.log("* left — /enter or /open a room to talk again");
			break;
		case "help":
			console.log("* /list  /open <name>  /enter <name>  /leave  /help");
			break;
		default:
			console.log(`* unknown command /${cmd} (try /help)`);
	}
}

// Run a strict directory verb (open or enter) and move into the room it returns,
// surfacing the wire's reason if it refuses.
async function tryMove(
	get: () => Promise<Ref>,
	name: string,
	verb: string,
): Promise<void> {
	try {
		await showRoom(await get(), name);
	} catch (err) {
		console.log(
			`* cannot ${verb} "${name}": ${err instanceof Error ? err.message : err}`,
		);
	}
}

// The live rooms, most-populated first.
function showRooms(): void {
	if (liveRooms.size === 0) {
		return void console.log("* no rooms yet, /open one");
	}
	const rows = [...liveRooms.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
	console.log(
		`* rooms: ${rows.map(([name, count]) => `${name} (${count})`).join(", ")}`,
	);
}

// Yield one trimmed line at a time as you type, splitting the raw stdin stream
// on newlines and holding any half-typed tail until the rest arrives.
async function* typedLines(): AsyncGenerator<string> {
	const decoder = new TextDecoder();
	let rest = "";
	for await (const chunk of Deno.stdin.readable) {
		const text = rest + decoder.decode(chunk, { stream: true });
		const pieces = text.split("\n");
		rest = pieces.pop() ?? ""; // the last piece has no newline yet
		for (const piece of pieces) yield piece.trim();
	}
	if (rest.trim().length > 0) yield rest.trim();
}
