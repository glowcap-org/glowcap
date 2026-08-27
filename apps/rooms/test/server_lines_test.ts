// What holding a reference lets somebody do: to a line, to the topic, to their
// own standing.
//
// None of these verbs ask who is calling. The reference went to whoever earned
// it and a member without one cannot form the request, so what is tested is
// that possession is enough and that losing it is enough to stop.

import { MAX_AWAY, MAX_TOPIC } from "../lib/limits.ts";
import { loopbackTcpDesignator } from "../lib/locator.ts";
import { Message, Room } from "../lib/room_client.ts";
import {
	assert,
	assertMatch,
	delay,
	dial,
	enterOrOpen,
	onPath,
	RACKET_CLIENT,
	roomsTest,
	ROOT,
	subscribeOnce,
	within,
	withServer,
} from "./support/rooms_server.ts";
import { spawnOwned, stopOwned } from "./support/children.ts";
import { lineBehavior, linkedStewardBehavior, stewardBehavior, topicBehavior } from "../server/lines.ts";
import type { RoomState } from "../server/registry.ts";
import { EDIT, GOVERNS, KICK, SET_TOPIC, WITHDRAW } from "../lib/protocol.ts";

Deno.test("line, topic, and moderator capabilities enforce exact data shapes", () => {
	const state = {} as RoomState;
	const refused = (run: () => unknown): boolean => {
		try {
			run();
			return false;
		} catch {
			return true;
		}
	};
	const line = lineBehavior(state, "ada", 1, [], null);
	assert(refused(() => line(EDIT, ["text", "surplus"])), "edit accepted surplus data");
	assert(refused(() => line(WITHDRAW, ["surplus"])), "withdraw accepted surplus data");
	assert(refused(() => stewardBehavior(state)(KICK, ["member", "surplus"])), "kick accepted surplus data");
	assert(refused(() => topicBehavior(state)(SET_TOPIC, ["topic", "surplus"])), "setTopic accepted surplus data");
	assert(
		refused(() => linkedStewardBehavior("room", "identity", () => true)(GOVERNS, ["surplus"])),
		"governs accepted surplus data",
	);
});

roomsTest(
	"racket one-shot client exits by its deadline while unrelated traffic continues",
	async () => {
		if (!(await onPath("racket"))) return;

		await withServer(async (port) => {
			const proc = spawnOwned("racket", {
				args: [
					"-y",
					RACKET_CLIENT,
					loopbackTcpDesignator(port),
					"general",
					"rkt-alan",
					"hello from racket",
					"rkt-alan,missing",
					"250",
				],
				cwd: ROOT,
				stdout: "piped",
				stderr: "piped",
			});

			let keepNoising = true;
			const noise = (async () => {
				for (let i = 0; keepNoising; i += 1) {
					await subscribeOnce(port, "general", `noise-${i}`).catch(() => {});
					await delay(40);
				}
			})();

			const timedOut = { kind: "timed out" } as const;
			const result = await Promise.race([
				proc.output(),
				// The client's 250 ms deadline starts after Racket has loaded the
				// binding and joined the room. This outer timer is only a hung-process
				// fuse, so it must also admit a cold worktree's module compilation.
				delay(10_000).then(() => timedOut),
			]);
			keepNoising = false;
			await noise;
			if ("kind" in result) {
				await stopOwned(proc);
				throw new Error(
					"racket client did not exit when the roster could not complete",
				);
			}

			const stderr = new TextDecoder().decode(result.stderr);
			assert(
				!result.success,
				"racket client should fail for an impossible roster",
			);
			assertMatch(stderr, /roster did not complete/);
			assertMatch(stderr, /missing: missing/);
			assert(
				!stderr.includes("missing: rkt-alan"),
				"local member should not be reported missing",
			);
		});
	},
);

roomsTest("holding a line's reference is the authority to change or withdraw it", async () => {
	await withServer(async (port) => {
		const author = await dial(loopbackTcpDesignator(port));
		const authorRoom = await Room.subscribe(author, await enterOrOpen(author, "edits"), "author");

		const reader = await dial(loopbackTcpDesignator(port));
		const readerRoom = await Room.subscribe(reader, await enterOrOpen(reader, "edits"), "reader");
		const heard = readerRoom.messages[Symbol.asyncIterator]();
		const next = async (): Promise<Message> => {
			let message: Message | null = null;
			while (message == null) {
				const { value, done } = await within(heard.next(), "the next line in the room");
				assert(!done && value != null, "the reader's stream ended early");
				// Skip the membership traffic; this test is about one line.
				if (value.presence == null) message = value;
			}
			return message;
		};

		// Posting answers with the line it made. Nothing here says who may change
		// it, because the reference going to this member is the whole of that.
		const line = await authorRoom.say("frist post");
		assert(line !== null, "post answered with no reference to the line it made");

		const said = await next();
		assert(said.text === "frist post", `the reader heard ${said.text}`);
		assert(said.change === "said", `a new line should be said, not ${said.change}`);
		assert(said.lineId !== undefined, "a line arrived without the id an edit would name");

		// Changing it reaches everybody who has it on screen, naming the same line.
		await line.edit("first post");
		const fixed = await next();
		assert(fixed.change === "edited", `an edit should be edited, not ${fixed.change}`);
		assert(fixed.lineId === said.lineId, "an edit named a different line than it changed");
		assert(fixed.text === "first post", `the edit carried ${fixed.text}`);
		assert(fixed.from === "author", `an edit should still be the author's, not ${fixed.from}`);

		// Taking it back names it once more, and saying so twice is somebody
		// making sure rather than doing something wrong.
		await line.withdraw();
		const gone = await next();
		assert(gone.change === "withdrawn", `a withdrawal should be withdrawn, not ${gone.change}`);
		assert(gone.lineId === said.lineId, "a withdrawal named a different line");
		await line.withdraw();

		// A withdrawn line stays withdrawn: editing one afterwards would put text
		// back on screen that its author had taken down.
		let refused: unknown = null;
		try {
			await line.edit("back again");
		} catch (error) {
			refused = error;
		}
		assert(refused !== null, "a withdrawn line let itself be edited back onto everybody's screen");
	});
});

roomsTest("a member's own standing is theirs to state, and the room tells the rest", async () => {
	await withServer(async (port) => {
		const first = await dial(loopbackTcpDesignator(port));
		const firstRoom = await Room.subscribe(first, await enterOrOpen(first, "standing"), "first");

		const other = await dial(loopbackTcpDesignator(port));
		const otherRoom = await Room.subscribe(other, await enterOrOpen(other, "standing"), "other");
		const heard = otherRoom.messages[Symbol.asyncIterator]();
		const nextAway = async (): Promise<{ name: string; reason: string }> => {
			for (let i = 0; i < 8; i++) {
				const { value, done } = await within(heard.next(), "a standing from the room");
				assert(!done && value !== undefined, "the other member's stream ended early");
				if (value.presence?.kind === "away") return value.presence;
			}
			throw new Error("no standing arrived");
		};

		// Nothing is handed over for this: the room writes the standing of the
		// membership that called, so a member can say it about themselves and
		// about nobody else.
		await firstRoom.away("back in ten");
		const gone = await nextAway();
		assert(gone.name === "first", `the room said ${gone.name} had stepped away`);
		assert(gone.reason === "back in ten", `the reason arrived as ${gone.reason}`);

		// Somebody arriving afterwards is told who is already away, on the same
		// line every later change arrives on.
		const late = await dial(loopbackTcpDesignator(port));
		const lateRoom = await Room.subscribe(late, await enterOrOpen(late, "standing"), "late");
		const lateHeard = lateRoom.messages[Symbol.asyncIterator]();
		let told: string | undefined;
		for (let i = 0; i < 8 && told === undefined; i++) {
			const { value } = await within(lateHeard.next(), "what a newcomer is told");
			if (value?.presence?.kind === "away") told = value.presence.reason;
		}
		assert(told === "back in ten", `a newcomer was told the standing was ${told}`);

		// Bare is back, which is what `/away` has meant in every client for thirty
		// years, and it reads as a change rather than as nothing said.
		await firstRoom.away("");
		const back = await nextAway();
		assert(back.reason === "", `coming back arrived as ${back.reason}`);

		// Authored text is never silently changed. A reason over the limit is
		// refused, and the exact longest accepted value arrives unchanged.
		let refused = "";
		await firstRoom.away("y".repeat(MAX_AWAY + 40)).catch((error) => {
			refused = error instanceof Error ? error.message : String(error);
		});
		assert(refused.includes(`${MAX_AWAY}`), `a long reason was not refused: ${refused}`);
		const longest = "y".repeat(MAX_AWAY);
		await firstRoom.away(longest);
		const accepted = await nextAway();
		assert(accepted.reason === longest, "the longest accepted away reason was changed");
	});
});

roomsTest("holding the topic capability is the authority to say what a room is about", async () => {
	await withServer(async (port) => {
		const first = await dial(loopbackTcpDesignator(port));
		const firstRoom = await Room.subscribe(first, await enterOrOpen(first, "topical"), "first");
		assert(firstRoom.canSetTopic, "subscribing did not answer with a topic to set");

		const other = await dial(loopbackTcpDesignator(port));
		const otherRoom = await Room.subscribe(other, await enterOrOpen(other, "topical"), "other");
		const heard = otherRoom.messages[Symbol.asyncIterator]();
		const next = async (): Promise<Message> => {
			let message: Message | null = null;
			while (message == null) {
				const { value, done } = await within(heard.next(), "the next line in the room");
				assert(!done && value != null, "the other member's stream ended early");
				if (value.presence == null) message = value;
			}
			return message;
		};

		// Setting it reaches everybody in the room, as a fact and as a sentence: a
		// client that has never heard of topics still shows the line saying it moved.
		await firstRoom.setTopic("what we are here for");
		const said = await next();
		assert(said.facts?.topic === "what we are here for", `the topic arrived as ${said.facts?.topic}`);
		assert(said.text.includes("what we are here for"), `the change said "${said.text}"`);

		// The room holds the topic, not whoever set it, so somebody arriving later
		// is told what they walked into.
		const late = await dial(loopbackTcpDesignator(port));
		const lateRoom = await Room.subscribe(late, await enterOrOpen(late, "topical"), "late");
		const lateHeard = lateRoom.messages[Symbol.asyncIterator]();
		let told: string | undefined;
		for (let i = 0; i < 8 && told === undefined; i++) {
			const { value } = await within(lateHeard.next(), "the topic a newcomer is told");
			told = value?.facts?.topic;
		}
		assert(told === "what we are here for", `a newcomer was told the topic was ${told}`);

		// Every member holds one: the room has no ranks to hand out, and the second
		// member setting it is not a permission being granted but a reference being
		// held.
		assert(otherRoom.canSetTopic, "a member who did not open the room holds no topic");
		await otherRoom.setTopic("");
		const cleared = await next();
		assert(cleared.facts?.topic === "", "taking the topic down did not read as an empty topic");

		// Too long is refused rather than silently cut, the same as a line.
		let refused: unknown = null;
		try {
			await firstRoom.setTopic("x".repeat(MAX_TOPIC + 1));
		} catch (error) {
			refused = error;
		}
		assert(refused !== null, "a topic past the room's cap was accepted");
	});
});

roomsTest("the room's own tidying cannot take back a line's authority", async () => {
	await withServer(async (port) => {
		const author = await dial(loopbackTcpDesignator(port));
		const room = await Room.subscribe(author, await enterOrOpen(author, "bounded"), "author");

		// A room that answered every post with a reference would end up holding one
		// per line said, so it lets go of the older ones. Letting go is the room
		// dropping its own hold, not a revocation: the member's reference is what
		// carries the authority, and it stays live because they hold it.
		//
		// Which makes this the test of the whole shape. A room that "tidied up" by
		// taking the authority back would pass every other check here and quietly
		// break the promise the design rests on, so it is checked from the far
		// side, where possession is all there is.
		const first = await room.say("the first thing said");
		assert(first !== null, "post answered with no reference to the line it made");
		for (let i = 0; i < 120; i++) await room.say(`line ${i}`);
		await first.edit("changed long afterwards");
	});
});
