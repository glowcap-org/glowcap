// Name vouchers, private rooms, and the room's own voice.

import { NICK_TAKEN } from "../../lib/errors.ts";
import { nickRefusal } from "../../lib/limits.ts";
import { loopbackTcpDesignator, roomsHost } from "../../lib/locator.ts";
import { DIRECTORY, ENTER, LEAVE, LIST, NOTIFY, OPEN, REGISTER, SUBSCRIBE, WATCH } from "../../lib/protocol.ts";
import { Directory, Room } from "../../lib/room_client.ts";
import {
	assert,
	assertMatch,
	delay,
	dial,
	enterOrOpen,
	registerAndWatch,
	resubscribeAndHold,
	roomsTest,
	subscribeOnce,
	trySubscribe,
	waitForMatch,
	within,
	withServer,
} from "../support/rooms_server.ts";
import { Ref } from "@pancake/runtime";
roomsTest("a name voucher seats its holder on a second connection under their own name", async () => {
	// A registered name is held by a connection, and the capability `register`
	// answers with is the holding, detached from it. A subscribe arriving on
	// another connection of the same Host — the shape a handed room reference or
	// a redeemed link creates — proves itself with a voucher that capability
	// minted, and is seated as the member rather than refused as a stranger.
	//
	// The second route is a byte pipe on another port: the same server behind a
	// second spelling of its address, so the Host's one-session-per-pair rule
	// does not fold the two dials into one.
	await withServer(async (port) => {
		const proxy = Deno.listen({ hostname: "127.0.0.1", port: 0 });
		const proxyPort = (proxy.addr as Deno.NetAddr).port;
		const pipes = (async () => {
			for await (const conn of proxy) {
				void (async () => {
					const up = await Deno.connect({ hostname: "127.0.0.1", port });
					void conn.readable.pipeTo(up.writable).catch(() => {});
					void up.readable.pipeTo(conn.writable).catch(() => {});
				})().catch(() => {});
			}
		})();
		const me = roomsHost();
		const dirPiped = await Directory.connect(`127.0.0.1:${proxyPort}`, (address) => dial(address, me));
		const dirDirect = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address, me));
		try {
			// The name is registered on the piped route.
			await dirPiped.register("bo", "127.0.0.1:1", () => {});

			// A bare subscribe on the direct route is a stranger claiming a held
			// name, which is the refusal the voucher exists to answer — asserted
			// first, so the pass below cannot be the check not running.
			const room = await dirDirect.open("lounge");
			let refused = "";
			try {
				await within(Room.subscribe(dirDirect.session, room, "bo"), "the bare subscribe", 5_000);
			} catch (err) {
				refused = err instanceof Error ? err.message : String(err);
			}
			assertMatch(refused, /held for direct messages/);

			// With the voucher, the same subscribe is the member arriving.
			const voucher = await dirPiped.nameVoucher();
			assert(voucher instanceof Uint8Array, "the name capability should mint a voucher");
			const seated = await within(
				Room.subscribe(dirDirect.session, room, "bo", undefined, voucher),
				"the vouched subscribe",
				5_000,
			);
			// The join announcement and then the welcome, both under the held name.
			const reader = seated.messages.getReader();
			const joined = await within(reader.read(), "the join line", 5_000);
			assert(
				joined.value !== undefined && /^bo joined\b/.test(joined.value.text),
				`the room did not seat the holder as bo: ${joined.value?.text}`,
			);
			const welcome = await within(reader.read(), "the welcome", 5_000);
			assert(
				welcome.value !== undefined && /welcome bo\b/.test(welcome.value.text),
				`the welcome does not greet the holder as bo: ${welcome.value?.text}`,
			);
			reader.releaseLock();

			// Spent is spent: the same bytes do not seat anybody twice.
			await seated.leave();
			let reused = "";
			try {
				await within(
					Room.subscribe(dirDirect.session, room, "bo", undefined, voucher),
					"the reused voucher",
					5_000,
				);
			} catch (err) {
				reused = err instanceof Error ? err.message : String(err);
			}
			assertMatch(reused, /held for direct messages/);
		} finally {
			await dirDirect.close();
			await dirPiped.close();
			proxy.close();
			await pipes.catch(() => {});
		}
	});
});

roomsTest("a private room is in no list, answers to no name, and takes no name from anybody", async () => {
	// The three ways a directory would otherwise give a room away, asked in the
	// two ways a client can learn what rooms there are: the whole list handed to
	// somebody arriving, and the changes pushed to somebody already here. A guard
	// on one of those is not a guard.
	await withServer(async (port) => {
		const maker = await dial(loopbackTcpDesignator(port));
		maker.serve().catch(() => {});
		const watcher = await dial(loopbackTcpDesignator(port));
		watcher.serve().catch(() => {});
		try {
			const directory = await maker.fetch(DIRECTORY);
			const watched = await watcher.fetch(DIRECTORY);
			// Watching before the room exists, so every change to the list since
			// then has been pushed to this inbox.
			const pushed: string[] = [];
			const inbox = watcher.spawn((verb, args) => {
				if (verb === NOTIFY) pushed.push(String(args[0]) + " " + String(args[1]));
				return null;
			});
			await watcher.send(watched, WATCH, [inbox]);

			const room = await maker.send(directory, OPEN, ["plans", true]);
			assert(room instanceof Ref, "opening a private room should return a room reference");
			// Somebody has to be in it, because an empty room is left out of the
			// list for an entirely different reason and would prove nothing.
			const heard = maker.spawn(() => null);
			await maker.send(room, SUBSCRIBE, ["ada", heard]);

			// Handed to somebody arriving now.
			const listed = await maker.send(directory, LIST, []);
			const names = Array.isArray(listed) ? listed.map((entry) => String((entry as unknown[])[0])) : [];
			assert(!names.includes("plans"), `a private room was in the list: ${JSON.stringify(names)}`);

			// And pushed to somebody already here.
			await delay(200);
			assert(
				!pushed.some((event) => event.endsWith(" plans")),
				`a private room was pushed to a watcher: ${JSON.stringify(pushed)}`,
			);

			// Its name is not a way in.
			let byName = "";
			try {
				await maker.send(directory, ENTER, ["plans"]);
			} catch (err) {
				byName = err instanceof Error ? err.message : String(err);
			}
			assertMatch(byName, /no room named "plans"/);

			// Nor is it taken from anybody: the name is a label, and a public room
			// may still be opened under it — a different room, which is what makes
			// "that name is taken" an answer this cannot give.
			const publicRoom = await maker.send(directory, OPEN, ["plans"]);
			assert(publicRoom instanceof Ref, "a private room should not take the public name");
		} finally {
			maker.close();
			watcher.close();
			await maker.serve().catch(() => {});
			await watcher.serve().catch(() => {});
		}
	});
});

Deno.test("a granted name refuses control and text-direction characters", () => {
	// A name flows unescaped into every client, and to a terminal client's
	// stdout — so a control character is an ANSI escape in every reader's
	// terminal, and a bidi override is one name visually wearing another. These
	// are refused; letters of every script, combining marks, and emoji are not.
	const unsafe: Record<string, string> = {
		escape: "al\x1b[2Jice",
		newline: "two\nlines",
		tab: "a\tb",
		del: "gone\x7f",
		"rtl override": "user\u202egnitpoofs",
		"ltr mark": "name\u200e",
		"line separator": "a\u2028b",
		"bidi isolate": "a\u2066b\u2069",
	};
	for (const [what, name] of Object.entries(unsafe)) {
		assert(nickRefusal(name) !== null, `a ${what} in a name was granted: ${JSON.stringify(name)}`);
	}
	// The room-wide mention words address everyone at once, so none of them is
	// grantable as a person's name, in any folding. The live proof below drives
	// "room" through both granting doors; these share that door's one gate
	// (`nickRefusal`), so the unit answer covers the rest of the vocabulary.
	for (const wide of ["here", "Here", "channel", "everyone", "EVERYONE", "all"]) {
		assert(nickRefusal(wide) !== null, `a room-wide word was grantable as a name: ${JSON.stringify(wide)}`);
	}
	// Legitimate names of any script, and an emoji, stay grantable.
	for (const ok of ["alice", "José", "田中", "Иван", "İlknur", "🦆duck", "a-2"]) {
		assert(nickRefusal(ok) === null, `a legitimate name was refused: ${JSON.stringify(ok)} → ${nickRefusal(ok)}`);
	}
});

roomsTest("the room's own voice is not a name anybody can wear", async () => {
	// Every client renders the sender "room" as the room itself: a system
	// banner, no avatar, no attribution — and exempt from ignoring, because a
	// system line is nobody's to silence. A member granted the name could speak
	// with all of that. Both doors that grant names share one refusal, and both
	// are asked here so the shared rule cannot quietly stop covering one.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			const room = await session.send(directory, OPEN, ["lounge"]);
			assert(room instanceof Ref, "open should answer a room");
			const inbox = session.spawn(() => null);
			for (const spelling of ["room", "Room", "ROOM"]) {
				let refused = "";
				try {
					await session.send(room, SUBSCRIBE, [spelling, inbox]);
				} catch (err) {
					refused = err instanceof Error ? err.message : String(err);
				}
				assertMatch(refused, /room's own voice/);
				refused = "";
				try {
					await session.send(directory, REGISTER, [spelling, "127.0.0.1:1", inbox]);
				} catch (err) {
					refused = err instanceof Error ? err.message : String(err);
				}
				assertMatch(refused, /room's own voice/);
			}
		} finally {
			session.close();
			await session.serve().catch(() => {});
		}
	});
});

roomsTest("rooms server frees a room name once its last member leaves", async () => {
	await withServer(async (port) => {
		// Opening a room then leaving empties it; the name is reusable, and a fresh
		// room starts the count over at 1.
		assertMatch(
			await subscribeOnce(port, "ephemeral", "first"),
			/1 in the room: first$/,
		);
		await waitForMatch(
			() => subscribeOnce(port, "ephemeral", "second"),
			/1 in the room: second$/,
		);
	});
});

roomsTest("rooms server grants each live nickname once per room", async () => {
	await withServer(async (port) => {
		const first = await trySubscribe(port, "lobby", "Claimed");
		assert(first.ok, "first claim should succeed");
		const duplicate = await trySubscribe(port, "lobby", "claimed");
		assert(!duplicate.ok, "duplicate live claim should fail");
		assert(duplicate.code === NICK_TAKEN, "duplicate live claim should be nick-taken");

		// The same nickname is free in a different room.
		const elsewhere = await trySubscribe(port, "annex", "claimed");
		assert(elsewhere.ok, "the same nick should be free in another room");
		await elsewhere.leave();

		await first.leave();

		const reclaimed = await trySubscribe(port, "lobby", "CLAIMED");
		assert(reclaimed.ok, "released name should be claimable again");
		await reclaimed.leave();
	});
});

roomsTest("rooms server will not grant a name a connected member still answers to", async () => {
	// A name outlives a room membership: leaving a room does not give up the
	// registration a member is reached by, because a direct line is not the
	// room's. So the room must not hand that name to the next person while the
	// first is still connected — the roster would show one of them and an
	// introduction under the name would reach the other.
	await withServer(async (port) => {
		const holder = await dial(loopbackTcpDesignator(port));
		holder.serve().catch(() => {});
		try {
			const holderDir = await holder.fetch(DIRECTORY);
			const room = await enterOrOpen(holder, "lobby");
			await holder.send(room, SUBSCRIBE, ["ada", holder.spawn(() => null)]);
			await registerAndWatch(holder, holderDir, "ada", loopbackTcpDesignator(port));

			// Ada leaves the room. Her membership is gone; her registration is not,
			// because a direct line does not belong to the room that introduced it.
			await holder.send(room, LEAVE, []);

			const impostor = await trySubscribe(port, "lobby", "ada");
			assert(
				!impostor.ok,
				"the room granted a name a still-connected member answers to for direct " +
					"messages; an introduction from the roster would reach the wrong person",
			);
			assert(impostor.code === NICK_TAKEN, "the refusal should read as nick-taken");

			// Only the held name is refused; the rule costs nobody else the room.
			const other = await trySubscribe(port, "lobby", "grace");
			assert(other.ok, "an unheld name should still be granted");
			await other.leave();
		} finally {
			holder.close();
			await holder.serve().catch(() => {});
		}
	});
});

roomsTest("rooms server resubscribe replaces one connection's claimed nickname", async () => {
	await withServer(async (port) => {
		const holder = await resubscribeAndHold(port, "general");

		const oldName = await trySubscribe(port, "general", "first-a");
		assert(oldName.ok, "old name should be released by resubscribe");
		const currentName = await trySubscribe(port, "general", "first-b");
		assert(
			!currentName.ok,
			"new name should remain claimed while holder lives",
		);
		assert(currentName.code === NICK_TAKEN, "held nick should be rejected as nick-taken");

		await oldName.leave();
		await holder.leave();
	});
});
