// A rooms chat client, written on glowcap actors in native Deno.
//
// It connects to the directory, enters the named room (opening it if it does not
// exist yet), publishes a local `inbox` actor, and hands the room a capability to
// that inbox when it subscribes. The room answers with a membership seat, and
// from then on the room calls the client back — the client never polls. It waits
// until everyone it expects is in the room, posts one line on its seat, and
// collects each expected member's line as the room pushes it back.
//
//   deno run --allow-ffi --allow-net client.ts 127.0.0.1:9099 general alice "hi" alice,bob,carol
//
// The first argument is the locator: a `host:port` joins over TCP, an
// `ocapn://<nodeid>.iroh?…` URI joins over iroh. The second is the room name.
//
// The last argument is the roster: a comma-separated list of the member nicks to
// expect (default: just you). The client posts only once every roster member is
// present, so an all-to-all broadcast is deterministic no matter what order the
// members connect in — it learns who is present from the structured presence the
// room attaches to each membership line (the roster on arrival and each join). It
// exits 0 once it has seen a line from every roster member, and 1 on timeout. Members
// outside the roster (people already chatting in an attached room, say) are
// printed but never counted, so a busy room cannot fake or break the assertion.
//
// This is the same application as the Python, Racket, Rust, and Zig clients, on
// one OCapN wire; the room cannot tell which language a member is written in.

import type { Ref } from "@glowcap/runtime";
import { Directory, readPresence } from "../../lib/room/client.ts";
import { readMembershipAnswer } from "../../lib/room/membership.ts";
import { releaseUnclaimedCapabilityArguments } from "../../lib/argument_custody.ts";
import { enterOrOpen } from "../../lib/enter_room.ts";
// The wire grammar this client switches on, generated from
// `tools/gen/rooms_protocol.zig` beside the same table every sibling client
// reads; `test/protocol_gen_test.ts` holds it to the server's own readers.
import { MEMBERSHIP_ENDED, NOTIFY, POST, ROOM_SENDER, SESSION_DEADLINE_MS, SUBSCRIBE } from "./protocol_gen.ts";
import { dialDirectory, isUriLocator, type RoomsDirectoryDial } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { Reachability } from "@glowcap/iroh";

export interface RunClientOptions {
	readonly dial: RoomsDirectoryDial;
	readonly roster?: readonly string[];
	readonly timeoutMs?: number;
}

/** Run one client session: enter the room, wait for every roster member to be
 * present, post `line`, and collect the chat line each roster member sends.
 * Resolves with the transcript of real chat lines (join announcements
 * excluded). */
export async function runClient(
	locator: string,
	roomName: string,
	nick: string,
	line: string,
	options: RunClientOptions,
): Promise<string[]> {
	const roster = options.roster ?? [nick];
	// The same whole-roster deadline the Python, Racket, Rust, and Zig clients hold.
	const timeoutMs = options.timeoutMs ?? SESSION_DEADLINE_MS;
	const dir = await Directory.connect(locator, options.dial);
	const session = dir.session;
	// Discovery: show the rooms that already have people in them, then follow the
	// live list, both the snapshot (`list`) and the change feed (`watch`).
	const live = await dir.list();
	console.log(
		`[${nick}] rooms: ${live.length ? live.map((r) => `${r.name} (${r.count})`).join(", ") : "(none yet)"}`,
	);
	await dir.watch((e) => console.log(`[${nick}] directory: ${e.kind} ${e.name} (${e.count})`));
	const room = await enterOrOpen(dir, roomName);

	const chatLines: string[] = [];
	const present = new Set<string>();
	const seen = new Set<string>();
	let posted = false;
	// The membership seat the room answers subscribe with; a line is posted on
	// it, never on the room. Null until the room has answered.
	let seat: Ref | null = null;
	const { promise: done, resolve: finish, reject: fail } = Promise.withResolvers<void>();

	function maybePost(): void {
		if (seat !== null && !posted && roster.every((n) => present.has(n))) {
			posted = true;
			void session.send(seat, POST, [line]).catch(fail);
		}
	}

	// The inbox the room calls back on. A system line may carry a structured
	// presence change after its text; an ordinary chat line does not.
	const inbox = session.spawn((verb, args) => {
		releaseUnclaimedCapabilityArguments(
			session,
			args,
			"the terminal room inbox could not return an unsupported capability",
		);
		if (verb !== NOTIFY) throw new Error(`inbox has no method ${verb}`);
		const from = typeof args[0] === "string" ? args[0] : "?";
		const text = typeof args[1] === "string" ? args[1] : "";
		console.log(`[${nick}] ${from}: ${text}`);
		if (args[2] === MEMBERSHIP_ENDED) {
			// The room's last word to this inbox (a steward's kick, say): no more
			// lines will reach it, so the roster wait cannot complete.
			if (args.length !== 3 || from !== ROOM_SENDER || text === "") {
				throw new Error("membership-ended notify takes one reason");
			}
			fail(new Error(`the room ended ${nick}'s membership: ${text}`));
			return null;
		}
		const presence = readPresence(args);
		if (presence) {
			// Membership arrives as structure. Only arrival and departure move a
			// member in or out of `present`; the other kinds are facts about a
			// member who is still here. The switch is over the library's typed
			// union, and the generated `ROOM_TAILS` is held to that union by
			// `test/protocol_gen_test.ts`, so a new kind fails to compile here.
			switch (presence.kind) {
				case "roster":
					for (const n of presence.names) present.add(n);
					break;
				case "join":
					present.add(presence.name);
					break;
				case "leave":
					present.delete(presence.name);
					break;
				case "away": // stepped away, or back: still a member
				case "typing": // ephemeral, never a membership change
				case "seat": // a bridge's seat for a member already counted
					break;
				default: {
					const unhandled: never = presence;
					throw new Error(`unhandled presence kind ${JSON.stringify(unhandled)}`);
				}
			}
		} else if (from !== ROOM_SENDER) {
			present.add(from); // a line is presence too
			chatLines.push(`${from}: ${text}`);
			if (roster.includes(from)) {
				seen.add(from);
				if (seen.size >= roster.length) finish();
			}
		}
		maybePost();
		return null;
	});

	// Subscribe, handing the room a capability to our inbox. The room answers
	// with the membership seat; the welcome and roster arrive as our first
	// `notify` (the roster line), not as part of that answer.
	seat = readMembershipAnswer(session, await session.send(room, SUBSCRIBE, [nick, inbox])).seat;
	maybePost();

	let timer: ReturnType<typeof setTimeout> | null = null;
	const timeout = new Promise<void>((_, reject) => {
		timer = setTimeout(() => reject(new Error("timeout")), timeoutMs);
	});
	try {
		await Promise.race([done, timeout]);
	} finally {
		if (timer != null) clearTimeout(timer);
		await session.close();
	}

	if (seen.size < roster.length) {
		const missing = roster.filter((n) => !seen.has(n)).join(", ");
		throw new Error(
			`${nick} saw lines from ${seen.size}/${roster.length} members before timeout (missing: ${missing})`,
		);
	}
	return chatLines;
}

if (import.meta.main) {
	const [locator, roomName, nick, line, rosterStr] = Deno.args;
	if (!locator || !roomName || !nick || line === undefined) {
		console.error(
			"usage: client.ts <locator> <room> <nick> <line> [roster]   (locator: host:port or an ocapn://…iroh URI; roster: comma-separated nicks to expect; default just you)",
		);
		Deno.exit(2);
	}
	try {
		await using runtime = await openRoomsRuntime({
			iroh: isUriLocator(locator) ? { reachability: Reachability.Direct } : undefined,
		});
		await runClient(
			locator,
			roomName,
			nick,
			line,
			{
				dial: (address) => dialDirectory(address, runtime),
				roster: rosterStr ? rosterStr.split(",") : [nick],
			},
		);
		Deno.exit(0);
	} catch (err) {
		console.error(
			`client ${nick} failed: ${err instanceof Error ? err.message : err}`,
		);
		Deno.exit(1);
	}
}
