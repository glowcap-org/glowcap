// Being in a room: entering one, leaving it, and who the room says is there.
//
// Membership is granted by subscribing and ends with the connection or a leave,
// and the room's word about it is what every member draws from — so these check
// what the room says, not what a client believes.

import { ATTACHMENT_REFUSED, TOO_MANY_ROOMS } from "../lib/errors.ts";
import { MAX_ATTACHMENT_BYTES, MAX_ROOMS_PER_CREATOR, MAX_SERVER_PENDING_BYTES } from "../lib/limits.ts";
import { loopbackTcpDesignator } from "../lib/locator.ts";
import { ATTACH, DIRECTORY, ENTER, LEAVE, OPEN, POST, SUBSCRIBE, WATCH } from "../lib/protocol.ts";
import { Room } from "../lib/room_client.ts";
import {
	assert,
	assertMatch,
	delay,
	dial,
	enterOrOpen,
	irohUsable,
	listRooms,
	refusalCode,
	roomsTest,
	subscribeOnce,
	subscribeTwiceAndClose,
	trySubscribe,
	waitForLine,
	waitForMatch,
	watchDirectory,
	watchRoom,
	withCapturedServer,
	within,
	withIrohServer,
	withServer,
} from "./support/rooms_server.ts";
import { Ref } from "@pancake/runtime";

roomsTest("rooms directory opens a room and rejects opening it twice", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			const room = await session.send(directory, OPEN, ["lounge"]);
			assert(room !== null, "open should return a room reference");

			let duplicateError = "";
			try {
				await session.send(directory, OPEN, ["lounge"]);
			} catch (err) {
				duplicateError = err instanceof Error ? err.message : String(err);
			}
			assertMatch(duplicateError, /room "lounge" already exists/);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("a connection cannot open rooms without limit", async () => {
	// An empty room is reclaimed only when its creator leaves, so a loop of
	// opens is memory the caller spends until then. Private opens never collide,
	// which is the sharpest form. A durable link is another way to create a live
	// room, and must spend the same budget rather than bypassing it.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			const linkedRef = await session.send(directory, OPEN, ["linked-limit"]);
			assert(linkedRef instanceof Ref, "opening the room to link should answer a room");
			const linked = await Room.subscribe(
				session,
				linkedRef,
				"linker",
			);
			const link = await linked.link(loopbackTcpDesignator(port));
			await linked.leave();
			for (let i = 0; i < MAX_ROOMS_PER_CREATOR; i += 1) {
				const room = await session.send(directory, OPEN, [`room-${i}`, true]);
				assert(room instanceof Ref, `open ${i} should answer a room`);
			}
			const refused = await refusalCode(() => session.send(directory, OPEN, ["one-too-many", true]));
			assert(refused === TOO_MANY_ROOMS, `the ${MAX_ROOMS_PER_CREATOR + 1}th open should refuse, got ${refused}`);
			const coldLinkedRef = await session.enliven(link);
			const linkedRefused = await refusalCode(() => Room.subscribe(session, coldLinkedRef, "overflow"));
			assert(
				linkedRefused === TOO_MANY_ROOMS,
				`a cold durable room bypassed the creator ceiling: ${linkedRefused}`,
			);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("rooms directory rejects entering a room that does not exist", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			let missingError = "";
			try {
				await session.send(directory, ENTER, ["nowhere"]);
			} catch (err) {
				missingError = err instanceof Error ? err.message : String(err);
			}
			assertMatch(missingError, /no room named "nowhere"/);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("the server's in-flight budget spans connections and comes back with them", async () => {
	await withServer(async (port) => {
		// Held media can be evicted, so its ceiling is enforced by dropping.
		// Bytes in flight cannot: nobody has seen them and there is no owner to
		// tell. So an upload the server has no room for is refused at attach,
		// against the size it declares, before a byte moves.
		//
		// The bound that matters spans connections. One connection was already
		// held to MAX_MESSAGE_FILES; what that leaves unbounded is the number
		// of connections, which is what this drives.
		const hog = await dial(loopbackTcpDesignator(port));
		hog.serve().catch(() => {});
		const other = await dial(loopbackTcpDesignator(port));
		other.serve().catch(() => {});
		try {
			const hogRoom = await enterOrOpen(hog, "reserved");
			await hog.send(hogRoom, SUBSCRIBE, ["hog", hog.spawn(() => null)]);
			const otherRoom = await enterOrOpen(other, "reserved");
			await other.send(otherRoom, SUBSCRIBE, ["other", other.spawn(() => null)]);

			// One connection declares its whole allowance at the largest file the
			// room takes, and writes none of it.
			const each = BigInt(MAX_ATTACHMENT_BYTES);
			const fillsBudget = Math.floor(MAX_SERVER_PENDING_BYTES / MAX_ATTACHMENT_BYTES);
			for (let i = 0; i < fillsBudget; i += 1) {
				const upload = await hog.send(hogRoom, ATTACH, [`hog${i}.bin`, "application/octet-stream", each]);
				assert(upload instanceof Ref, "a connection's own allowance should be admitted");
			}

			// A second connection is refused, because the budget is the server's.
			const blocked = await refusalCode(() =>
				other.send(otherRoom, ATTACH, ["mine.bin", "application/octet-stream", each])
			);
			assert(blocked === ATTACHMENT_REFUSED, `expected attachment-refused, got ${blocked}`);

			// The hog leaves. Every reservation it held comes back with it, so the
			// second connection can declare the same bytes. A departure that leaked
			// its reservations would leave this refused for the life of the server.
			hog.close();
			await hog.serve().catch(() => {});
			await waitForMatch(
				async () =>
					(await refusalCode(() =>
						other.send(otherRoom, ATTACH, ["mine.bin", "application/octet-stream", each])
					)) ?? "admitted",
				/^admitted$/,
			);
		} finally {
			other.close();
			await other.serve().catch(() => {});
		}
	});
});

roomsTest("rooms in different rooms do not see each other's posts", async () => {
	await withServer(async (port) => {
		const lounge = await watchRoom(port, "lounge", "in-lounge");
		const garden = await watchRoom(port, "garden", "in-garden");
		await waitForLine(lounge.lines, /^room: in-lounge joined/);
		await waitForLine(garden.lines, /^room: in-garden joined/);

		const talker = await watchRoom(port, "lounge", "talker");
		await waitForLine(lounge.lines, /^room: talker joined \(2 here\)$/);

		// The garden never hears the lounge fill up, and the same nick is free there.
		await delay(150);
		assert(
			!garden.lines.some((line) => /talker/.test(line)),
			`garden should not see lounge traffic, got ${JSON.stringify(garden.lines)}`,
		);

		await lounge.leave();
		await talker.leave();
		await garden.leave();
	});
});

roomsTest("rooms server removes members that close cleanly", async () => {
	await withServer(async (port) => {
		assertMatch(
			await subscribeOnce(port, "general", "first"),
			/^in the room: first$/,
		);

		await waitForMatch(
			() => subscribeOnce(port, "general", "second"),
			/^in the room: second$/,
		);
	});
});

roomsTest("rooms server removes every membership for a closed connection", async () => {
	await withServer(async (port) => {
		await subscribeTwiceAndClose(port, "general");

		await waitForMatch(
			() => subscribeOnce(port, "general", "second"),
			/^in the room: second$/,
		);
	});
});

roomsTest("rooms server retires observed disconnects before broadcasting leaves", async () => {
	const stderr = await withCapturedServer(async (port) => {
		const survivor = await watchRoom(port, "general", "survivor");
		const first = await trySubscribe(port, "general", "first");
		const second = await trySubscribe(port, "general", "second");
		assert(first.ok && second.ok, "the departing members should both join");

		// Both close calls begin before either waiter yields. Their independent TCP
		// EOFs may still reach the server in one native drain or two: concurrency at
		// the callers is not authority over network arrival order. In either case a
		// leave count may include only members whose close has not yet been observed,
		// and the last departure must leave the survivor alone.
		await Promise.all([first.leave(), second.leave()]);
		await waitForLine(survivor.lines, /^room: first left \([12] here\)$/);
		await waitForLine(survivor.lines, /^room: second left \([12] here\)$/);
		const leaves = survivor.lines.filter((line) => /^room: (first|second) left/.test(line));
		assert(leaves.length === 2, `expected exactly two departures, got ${JSON.stringify(leaves)}`);
		assert(leaves[1].endsWith("(1 here)"), `the final departure did not leave one survivor: ${leaves[1]}`);
		await survivor.leave();
	});
	assert(!stderr.includes("notify to"), `disconnect cleanup attempted a stale notify:\n${stderr}`);
	assert(!stderr.includes("SessionCondemned"), `disconnect cleanup reached a condemned session:\n${stderr}`);
});

roomsTest("rooms server announces members leaving", async () => {
	await withServer(async (port) => {
		const watcher = await watchRoom(port, "general", "watcher");
		const leaver = await watchRoom(port, "general", "leaver");
		await waitForLine(watcher.lines, /^room: leaver joined \(2 here\)$/);

		await leaver.leave();

		await waitForLine(watcher.lines, /^room: leaver left \(1 here\)$/);
		await watcher.leave();
	});
});

roomsTest("rooms directory lists the live rooms with member counts", async () => {
	await withServer(async (port) => {
		const alpha = await watchRoom(port, "alpha", "a1");
		const beta = await watchRoom(port, "beta", "b1");
		const beta2 = await watchRoom(port, "beta", "b2");
		await waitForLine(beta.lines, /^room: b2 joined \(2 here\)$/);

		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const rooms = new Map(await listRooms(session));
			assert(
				rooms.get("alpha") === 1,
				`alpha should have 1 member, got ${rooms.get("alpha")}`,
			);
			assert(
				rooms.get("beta") === 2,
				`beta should have 2 members, got ${rooms.get("beta")}`,
			);

			// A room opened but not yet subscribed has no members, so it stays out of
			// the live list until someone is actually in it.
			const directory = await session.fetch(DIRECTORY);
			await session.send(directory, OPEN, ["ghost"]);
			const afterOpen = new Map(await listRooms(session));
			assert(
				!afterOpen.has("ghost"),
				"an empty just-opened room must not be listed",
			);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}

		await alpha.leave();
		await beta.leave();
		await beta2.leave();
	});
});

roomsTest("rooms directory pushes open/count/close deltas to a watcher", async () => {
	await withServer(async (port) => {
		const watcherConn = await dial(loopbackTcpDesignator(port));
		const watch = await watchDirectory(watcherConn);

		const m1 = await watchRoom(port, "wroom", "m1");
		await waitForLine(watch.events, /^opened wroom 1$/);
		const m2 = await watchRoom(port, "wroom", "m2");
		await waitForLine(watch.events, /^count wroom 2$/);

		await m2.leave();
		await waitForLine(watch.events, /^count wroom 1$/);
		await m1.leave();
		await waitForLine(watch.events, /^closed wroom 0$/);

		watcherConn.close();
		await watcherConn.serve().catch(() => {});
	});
});

roomsTest("a room leave drops just that membership, keeping the connection", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const one = await enterOrOpen(session, "one");
			const two = await enterOrOpen(session, "two");
			const inbox = session.spawn(() => null);
			await session.send(one, SUBSCRIBE, ["solo", inbox]);
			await session.send(two, SUBSCRIBE, ["solo", inbox]);

			// Leaving "one" (its only member) closes it; "two" survives on the same
			// still-open session.
			await session.send(one, LEAVE, []);
			const rooms = new Map(await listRooms(session));
			assert(!rooms.has("one"), "left room should be gone");
			assert(
				rooms.get("two") === 1,
				"the other room should remain on this session",
			);

			// The connection is still usable: we can post in the room we kept.
			await session.send(two, POST, ["still here"]);
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("the directory answers the first message a fresh connection sends", async () => {
	if (!(await irohUsable())) return; // needs `zig build iroh-abi` (cargo)
	// A loop-backed listener dispatches an accepted session's first message as
	// it steps, which can be before the accepting code has run at all. The
	// directory used to be published onto each session as it arrived, so a dial
	// that fetched immediately raced that publish and lost about three times in
	// four, and losing was answered `unknown swissnum` — a room that was there
	// telling a member it was not. Published on the Host, it exists before any
	// connection does.
	//
	// Repeated because the failure was a race rather than a rule: one round
	// passing proves nothing, and the odds of six passing by luck are small.
	await withIrohServer(async (uri) => {
		for (let round = 1; round <= 6; round++) {
			const session = await dial(uri);
			session.serve().catch(() => {});
			// No settling wait between opening the connection and asking, which is
			// the whole of what this holds.
			await session.fetch(DIRECTORY);
			session.close();
		}
	});
});

roomsTest("a connection watching the directory twice is watching it once", async () => {
	await withServer(async (port) => {
		const watcherConn = await dial(loopbackTcpDesignator(port));
		const watch = await watchDirectory(watcherConn);

		// The same connection asks again. Every room event walks the watcher list,
		// so a second row here would make each join and departure anywhere on this
		// server do its work twice for this one peer, and nothing bounds how many
		// times it may ask.
		const directory = await watcherConn.fetch(DIRECTORY);
		const second = watcherConn.spawn((_verb, args) => {
			watch.events.push(`${args[0]} ${args[1]} ${Number(args[2])}`);
			return null;
		});
		await watcherConn.send(directory, WATCH, [second]);

		const member = await watchRoom(port, "echoing", "one");
		await waitForLine(watch.events, /^opened echoing 1$/);
		// A count delta after it, so the open above has been fully delivered by the
		// time this is counted: a second copy would already be in the list.
		const another = await watchRoom(port, "echoing", "two");
		await waitForLine(watch.events, /^count echoing 2$/);
		const opens = watch.events.filter((event) => event === "opened echoing 1").length;
		assert(opens === 1, `one connection watching twice was told the room opened ${opens} times`);

		await member.leave();
		await another.leave();
		watcherConn.close();
		await watcherConn.serve().catch(() => {});
	});
});

roomsTest("one connection re-entering a room keeps its place, and a leave after it would not", async () => {
	await withServer(async (port) => {
		const member = await dial(loopbackTcpDesignator(port));
		const ref = await enterOrOpen(member, "revolving");
		const first = await Room.subscribe(member, ref, "ada");

		const watcher = await dial(loopbackTcpDesignator(port));
		const watching = await Room.subscribe(watcher, await enterOrOpen(watcher, "revolving"), "watcher");
		const seen = watching.messages.getReader();

		// Re-entering is one connection re-claiming its place: the room replaces
		// the record rather than seating a second member under one name. This is
		// what a page does when a room stops delivering under a live connection,
		// and it is the only way back into a room whose history it still holds.
		const second = await Room.subscribe(member, ref, "ada");
		first.replaced();
		let refusedAfterReentry = "";
		await second.say("still here").catch((err) => {
			refusedAfterReentry = err instanceof Error ? err.message : String(err);
		});
		assert(
			refusedAfterReentry === "",
			`re-entering took back the place it had just made: ${refusedAfterReentry}`,
		);

		let heard = "";
		while (heard === "") {
			const { done, value } = await within(seen.read(), "the re-entered member to be heard");
			if (done) break;
			if (value.from === "ada") heard = value.text;
		}
		assert(heard === "still here", `a re-entered member was not heard: ${JSON.stringify(heard)}`);

		// And why `replaced` exists rather than `leave`. A departure is keyed by the
		// connection, so a leave sent on the membership that was replaced takes back
		// the place the re-entry had just made, leaving a member who believes they
		// are in a room the room no longer has them in.
		await first.leave();
		let refused = "";
		await second.say("anybody there").catch((err) => {
			refused = err instanceof Error ? err.message : String(err);
		});
		assert(
			refused !== "",
			"a leave on a replaced membership left the re-entered one standing, so the two are not one place",
		);

		seen.releaseLock();
	});
});
