// Directory registration: one nick per connection, and introducing inboxes.

import { Ref, type Session } from "@pancake/runtime";
import { inboxPublisher } from "../../../lib/dm_inbox.ts";
import {
	INTRODUCTION_PENDING,
	NICK_TAKEN,
	NICK_TOO_LONG,
	PEER_OFFLINE,
	ROOM_TOO_LONG,
	RoomError,
} from "../../../lib/errors.ts";
import { DIRECT_REQUEST_COALESCE_MS, MAX_DM_INBOXES, MAX_NICK, MAX_ROOM } from "../../../lib/limits.ts";
import { loopbackTcpDesignator, roomsHost } from "../../../lib/locator.ts";
import {
	DIRECT_REQUESTED,
	DIRECTORY,
	INTRODUCE,
	MEMBER_REGISTRATION,
	NOTIFY,
	OFFER_INBOX,
	OPEN,
	REGISTER,
	REQUEST_DIRECT,
} from "../../../lib/protocol.ts";
import { Directory } from "../../../lib/room/client.ts";
import {
	directRequestNoticeDue,
	dropIntroductions,
	registerMember,
	registrationOf,
} from "../../../server/introductions.ts";
import { RoomServer } from "../../../server/room_server.ts";
import {
	assert,
	delay,
	dial,
	refusalCode,
	registerAndWatch,
	roomsTest,
	withServer,
} from "../../support/rooms_server.ts";

Deno.test("reciprocal direct request pressure expires instead of consuming a registration forever", () => {
	const requests = new Map<string, number>();
	for (let i = 0; i < MAX_DM_INBOXES; i += 1) requests.set(`peer-${i}`, 0);
	assert(
		directRequestNoticeDue(requests, "next-peer", DIRECT_REQUEST_COALESCE_MS),
		"an expired request window did not admit the next peer",
	);
	assert(requests.size === 1 && requests.has("next-peer"), "expired reciprocal requests remained retained");

	assert(
		!directRequestNoticeDue(requests, "next-peer", DIRECT_REQUEST_COALESCE_MS + 1),
		"a repeated request inside the coalescing window emitted another notice",
	);
	assert(
		directRequestNoticeDue(requests, "next-peer", DIRECT_REQUEST_COALESCE_MS * 2),
		"the same peer could not request another route after the coalescing window",
	);
});

Deno.test("reciprocal direct requests enforce their active window bound", () => {
	const requests = new Map<string, number>();
	for (let i = 0; i < MAX_DM_INBOXES; i += 1) requests.set(`peer-${i}`, 1);
	let refused = "";
	try {
		directRequestNoticeDue(requests, "one-too-many", 1);
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assert(refused.includes(`${MAX_DM_INBOXES}`), "the active reciprocal request ceiling was not enforced");
	assert(requests.size === MAX_DM_INBOXES, "a refused reciprocal request changed the active window");
});

Deno.test("registration construction failure returns the inbox without claiming a name", () => {
	const inbox = Object.create(Ref.prototype) as Ref;
	const released: Ref[] = [];
	const session = {
		spawn: () => {
			throw new Error("name capability spawn refused");
		},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const server = new RoomServer();
	let refusal = "";
	try {
		registerMember(server, "bot", "127.0.0.1:1", inbox, session);
	} catch (error) {
		refusal = error instanceof Error ? error.message : String(error);
	}
	assert(refusal === "name capability spawn refused", "registration construction hid its refusal");
	assert(released.length === 1 && released[0] === inbox, "registration construction retained the offered inbox");
	assert(
		registrationOf(server.live, session) === null,
		"registration construction claimed a name before capability commit",
	);
});

Deno.test("failed nickname replacement preserves the prior registration", () => {
	const firstInbox = Object.create(Ref.prototype) as Ref;
	const replacementInbox = Object.create(Ref.prototype) as Ref;
	const nameCapability = Object.create(Ref.prototype) as Ref;
	const released: Ref[] = [];
	let refuseSpawn = false;
	const session = {
		spawn: () => {
			if (refuseSpawn) throw new Error("replacement name capability refused");
			return nameCapability;
		},
		tell: () => Promise.resolve(),
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const server = new RoomServer();
	try {
		registerMember(server, "first", "127.0.0.1:1", firstInbox, session);
		const prior = registrationOf(server.live, session);
		refuseSpawn = true;
		let refusal = "";
		try {
			registerMember(server, "replacement", "127.0.0.1:1", replacementInbox, session);
		} catch (error) {
			refusal = error instanceof Error ? error.message : String(error);
		}
		assert(refusal === "replacement name capability refused", "replacement construction hid its refusal");
		assert(
			registrationOf(server.live, session) === prior,
			"replacement construction withdrew the prior registration",
		);
		assert(
			released.length === 1 && released[0] === replacementInbox,
			"replacement construction released prior registration authority",
		);
	} finally {
		dropIntroductions(server, session);
	}
});

roomsTest("rooms directory registers a member and acknowledges the name", async () => {
	await withServer(async (port) => {
		const exporter = await dial(loopbackTcpDesignator(port));
		exporter.serve().catch(() => {});
		const exporterDir = await exporter.fetch(DIRECTORY);
		let registered = false;
		const regInbox = exporter.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") registered = true;
			return null;
		});
		await exporter.send(exporterDir, REGISTER, [
			"bot",
			loopbackTcpDesignator(port),
			regInbox,
		]);
		const deadline = Date.now() + 3_000;
		while (!registered && Date.now() < deadline) await delay(25);
		assert(registered, "member should receive notify(registered)");

		exporter.close();
		await exporter.serve().catch(() => {});
	});
});

roomsTest("a directory watch atomically includes existing registration claims", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const member = await Directory.connect(locator, (address) => dial(address));
		const registrationId = await member.register("bob", locator);
		const observer = await Directory.connect(locator, (address) => dial(address));
		const peers: { name: string; registrationId: string }[] = [];
		try {
			await observer.watch((event) => {
				if (event.kind === "registered") peers.push({ name: event.name, registrationId: event.registrationId });
			});
			assert(
				JSON.stringify(peers) === JSON.stringify([{ name: "bob", registrationId }]),
				"the watch baseline did not carry the exact existing registration",
			);
		} finally {
			await observer.close();
			await member.close();
		}
	});
});

roomsTest(
	"rooms directory introduces only to the inbox a member minted for the caller",
	async () => {
		// The directory's own rules. That the offered inbox then carries a real direct
		// message is the `demo-rooms-dm` gate's job; here nothing dials, so the test
		// stays fast and needs no second listener.
		await withServer(async (port) => {
			const bobHost = roomsHost();
			const bob = await dial(loopbackTcpDesignator(port), bobHost);
			bob.serve().catch(() => {});
			const bobDir = await bob.fetch(DIRECTORY);
			let bobAck = false;
			let bobClaim = "";
			let askedFor: string | null = null;
			let directRequestedBy: string | null = null;
			const bobReg = bob.spawn((verb, args) => {
				if (verb !== NOTIFY) return null;
				if (args[0] === "registered" && typeof args[2] === "string") {
					bobClaim = args[2];
					bobAck = true;
				}
				if (args[0] === "mintInboxFor" && typeof args[1] === "string") askedFor = args[1];
				if (args[0] === DIRECT_REQUESTED && typeof args[1] === "string") directRequestedBy = args[1];
				return null;
			});
			await bob.send(bobDir, REGISTER, ["bob", loopbackTcpDesignator(port), bobReg]);
			const bobDeadline = Date.now() + 3_000;
			while (!bobAck && Date.now() < bobDeadline) await delay(25);
			assert(bobAck, "bob should be registered");

			const carol = await dial(loopbackTcpDesignator(port));
			carol.serve().catch(() => {});
			const carolDir = await carol.fetch(DIRECTORY);
			let carolAck = false;
			let carolClaim = "";
			let introducible = false;
			const carolReg = carol.spawn((verb, args) => {
				if (verb !== NOTIFY) return null;
				if (args[0] === "registered" && typeof args[2] === "string") {
					carolClaim = args[2];
					carolAck = true;
				}
				if (args[0] === "introducible" && args[1] === "bob") introducible = true;
				return null;
			});
			await carol.send(carolDir, REGISTER, ["carol", "127.0.0.1:1", carolReg]);
			const carolDeadline = Date.now() + 3_000;
			while (!carolAck && Date.now() < carolDeadline) await delay(25);
			assert(carolAck, "carol should be registered");

			// Bob has offered nothing, so this is refused and Bob is asked for an inbox
			// for Carol, by the name the directory reads off her connection.
			let refused: string | null = null;
			try {
				await carol.send(carolDir, INTRODUCE, ["bob", bobClaim]);
			} catch (err) {
				refused = err instanceof Error ? err.message : String(err);
			}
			assert(refused !== null, "a first introduce should be refused");
			assert(
				RoomError.from(refused)?.code === INTRODUCTION_PENDING,
				`expected introduction-pending, got ${refused}`,
			);
			const askDeadline = Date.now() + 3_000;
			while (askedFor === null && Date.now() < askDeadline) await delay(25);
			assert(askedFor === "carol", `expected bob to be asked for carol, got ${askedFor}`);
			await carol.send(carolDir, REQUEST_DIRECT, ["bob", bobClaim]);
			const requestDeadline = Date.now() + 3_000;
			while (directRequestedBy == null && Date.now() < requestDeadline) await delay(25);
			assert(directRequestedBy === "carol", "bob was not told who requested the reciprocal direct route");

			// Bob offers one; Carol is told she may ask again.
			bobHost.publishGiftable("inbox-for-carol", () => null);
			const offered = bob.publishedRef("inbox-for-carol");
			assert(offered !== null, "the giftable should hold a position on bob's room session");
			await bob.send(bobDir, OFFER_INBOX, ["carol", carolClaim, offered]);
			const okDeadline = Date.now() + 3_000;
			while (!introducible && Date.now() < okDeadline) await delay(25);
			assert(introducible, "carol should hear that bob is introducible");

			// An unregistered caller has no name an inbox could have been minted for.
			const stranger = await dial(loopbackTcpDesignator(port));
			stranger.serve().catch(() => {});
			const strangerDir = await stranger.fetch(DIRECTORY);
			let strangerRefused = false;
			try {
				await stranger.send(strangerDir, INTRODUCE, ["bob", bobClaim]);
			} catch {
				strangerRefused = true;
			}
			assert(strangerRefused, "an unregistered caller should not be introduced");

			stranger.close();
			carol.close();
			bob.close();
			await Promise.allSettled([
				stranger.serve().catch(() => {}),
				carol.serve().catch(() => {}),
				bob.serve().catch(() => {}),
			]);
		});
	},
);

roomsTest("rooms directory refuses a register whose nick is too long", async () => {
	// The one place this can be held. A registered nick becomes the key every
	// member files an inbox under and the seed of a bootstrap name they keep for
	// good, so an unbounded name here is an unbounded allocation the caller spends
	// in every member it is introduced to. Clients cap their own input; only the
	// directory caps everyone's.
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const inbox = session.spawn(() => null);
		const code = await refusalCode(() =>
			session.send(directory, REGISTER, [
				"x".repeat(MAX_NICK + 1),
				loopbackTcpDesignator(port),
				inbox,
			])
		);
		assert(code === NICK_TOO_LONG, `expected nick-too-long, got ${code}`);

		// The directory is still serving, and a name at the limit is fine.
		const ok = await refusalCode(() =>
			session.send(directory, REGISTER, [
				"x".repeat(MAX_NICK),
				loopbackTcpDesignator(port),
				inbox,
			])
		);
		assert(ok === null, `a name at the limit should register, got ${ok}`);

		session.close();
		await session.serve().catch(() => {});
	});
});

roomsTest("rooms directory refuses a room name that is too long", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		const directory = await session.fetch(DIRECTORY);
		const code = await refusalCode(() => session.send(directory, OPEN, ["x".repeat(MAX_ROOM + 1)]));
		assert(code === ROOM_TOO_LONG, `expected room-too-long, got ${code}`);

		const accepted = await refusalCode(() => session.send(directory, OPEN, ["x".repeat(MAX_ROOM)]));
		assert(accepted === null, `a room name at the limit should open, got ${accepted}`);
		session.close();
		await session.serve().catch(() => {});
	});
});

roomsTest(
	"rooms directory does not hand a nickname's next holder the last one's inbox",
	async () => {
		// A registered name outlives its holders, and the inboxes other members
		// offered for it are filed under the name, not the person. Leaving them behind
		// would introduce whoever claims the name next to a capability minted for
		// somebody else, and the caller's interface would paint their messages as that
		// person's with nothing left to doubt.
		await withServer(async (port) => {
			const carolHost = roomsHost();
			const carol = await dial(loopbackTcpDesignator(port), carolHost);
			carol.serve().catch(() => {});
			const carolDir = await carol.fetch(DIRECTORY);
			const carolSaw = await registerAndWatch(carol, carolDir, "carol", "127.0.0.1:1");

			const bob = await dial(loopbackTcpDesignator(port));
			bob.serve().catch(() => {});
			const bobDir = await bob.fetch(DIRECTORY);
			const bobSaw = await registerAndWatch(bob, bobDir, "bob", loopbackTcpDesignator(port));

			// Carol offers Bob an inbox, and Bob hears that she is introducible.
			carolHost.publishGiftable("carol-inbox-for-bob", () => null);
			const offered = carol.publishedRef("carol-inbox-for-bob");
			assert(offered !== null, "the giftable should hold a position on carol's session");
			await carol.send(carolDir, OFFER_INBOX, ["bob", bobSaw.registrationId, offered]);
			const okDeadline = Date.now() + 3_000;
			while (bobSaw.introducible.length === 0 && Date.now() < okDeadline) await delay(25);
			assert(bobSaw.introducible.includes("carol"), "bob should hear carol is introducible");
			assert(carolSaw.askedFor.length === 0, "carol was not asked for that inbox");

			// Bob goes, and Mallory claims the name he gave up.
			bob.close();
			await bob.serve().catch(() => {});
			const goneDeadline = Date.now() + 3_000;
			let free: string | null = "held";
			const mallory = await dial(loopbackTcpDesignator(port));
			mallory.serve().catch(() => {});
			const malloryDir = await mallory.fetch(DIRECTORY);
			const malloryInbox = mallory.spawn(() => null);
			while (free !== null && Date.now() < goneDeadline) {
				free = await refusalCode(() =>
					mallory.send(malloryDir, REGISTER, ["bob", "127.0.0.1:2", malloryInbox])
				);
				if (free !== null) await delay(25);
			}
			assert(free === null, `mallory should get the freed name, refused ${free}`);
			const replacementClaim = await carol.send(carolDir, MEMBER_REGISTRATION, ["bob"]);
			assert(typeof replacementClaim === "string", "the replacement registration had no claim");
			assert(
				replacementClaim !== bobSaw.registrationId,
				"the replacement holder inherited Bob's registration claim",
			);
			const staleDirect = await refusalCode(() =>
				carol.send(carolDir, INTRODUCE, ["bob", bobSaw.registrationId])
			);
			assert(staleDirect === PEER_OFFLINE, `the old Bob claim reached the replacement holder: ${staleDirect}`);

			// The inbox Carol minted for the real Bob is not Mallory's to be handed.
			const code = await refusalCode(() =>
				mallory.send(malloryDir, INTRODUCE, ["carol", carolSaw.registrationId])
			);
			assert(code === INTRODUCTION_PENDING, `expected introduction-pending, got ${code}`);
			const askDeadline = Date.now() + 3_000;
			while (carolSaw.askedFor.length === 0 && Date.now() < askDeadline) await delay(25);
			assert(
				carolSaw.askedFor.includes("bob"),
				"carol should be asked to mint a fresh inbox for the new bob",
			);

			mallory.close();
			carol.close();
			await Promise.allSettled([
				mallory.serve().catch(() => {}),
				carol.serve().catch(() => {}),
			]);
		});
	},
);

roomsTest("a member re-offers its inboxes after a second registration, minting none", async () => {
	// A re-register is a fresh start on the name, so the directory drops what the
	// previous registration collected and asks again. Both halves have to hold: the
	// offerer must answer that ask, or the member is permanently un-DM-able, and it
	// must answer with the inbox it already published, because nothing withdraws a
	// giftable and a second one would answer forever under a name nobody can take
	// back.
	await withServer(async (port) => {
		const asker = await dial(loopbackTcpDesignator(port));
		asker.serve().catch(() => {});
		const askerDir = await asker.fetch(DIRECTORY);
		const askerSaw = await registerAndWatch(asker, askerDir, "carol", "127.0.0.1:1");

		const memberHost = roomsHost();
		let dir: Directory | null = null;
		dir = await Directory.connect(
			loopbackTcpDesignator(port),
			(l) => dial(l, memberHost),
		);
		let mints = 0;
		const offerer = inboxPublisher(memberHost).offerer({
			dir: () => dir,
			behaviorFor: () => {
				mints += 1;
				return () => null;
			},
		});
		const locator = loopbackTcpDesignator(port);
		const firstMemberClaim = await dir.register("member", locator, offerer.offer);
		offerer.offer("carol", askerSaw.registrationId);
		const first = Date.now() + 3_000;
		while (askerSaw.introducible.length < 1 && Date.now() < first) await delay(25);
		assert(askerSaw.introducible.includes("member"), "the first offer should land");
		assert(mints === 1, `expected one mint, saw ${mints}`);

		// Register again on the live session, the shipped path for a nick change.
		const secondMemberClaim = await dir.register("member", locator, offerer.offer);
		assert(firstMemberClaim !== secondMemberClaim, "a re-registration reused its incarnation");
		const code = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["member", secondMemberClaim]));
		assert(
			code === INTRODUCTION_PENDING,
			`the re-register should clear the offer, got ${code}`,
		);

		// That refusal asked the member again; the offerer answers with the same
		// published inbox.
		const second = Date.now() + 3_000;
		while (askerSaw.introducible.length < 2 && Date.now() < second) await delay(25);
		assert(askerSaw.introducible.length >= 2, "the member should offer again when asked");
		assert(mints === 1, `a re-offer must not mint a second inbox, saw ${mints}`);

		asker.close();
		await dir.close();
		await asker.serve().catch(() => {});
		await memberHost.close();
	});
});

roomsTest("a refused nickname change preserves the current name capability", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const member = await Directory.connect(locator, (address) => dial(address));
		const holder = await Directory.connect(locator, (address) => dial(address));
		try {
			await member.register("alice", locator);
			await holder.register("bob", locator);
			let refused = false;
			try {
				await member.register("bob", locator);
			} catch (error) {
				refused = RoomError.from(error instanceof Error ? error.message : String(error))?.code === NICK_TAKEN;
			}
			assert(refused, "the directory did not refuse a nickname held by another member");
			assert(
				await member.nameVoucher() != null,
				"a refused nickname change discarded the current registration's name capability",
			);
		} finally {
			await holder.close();
			await member.close();
		}
	});
});

roomsTest("rooms directory keeps one registered nick per connection", async () => {
	// `registeredNickOf` reads a caller's own name off the registry, so a
	// connection holding two rows makes "you" a matter of which one is found
	// first. A nick change re-registers on the live session, so this is the
	// shipped path, not a hypothetical.
	await withServer(async (port) => {
		const member = await dial(loopbackTcpDesignator(port));
		member.serve().catch(() => {});
		const memberDir = await member.fetch(DIRECTORY);
		const alice = await registerAndWatch(member, memberDir, "alice", loopbackTcpDesignator(port));
		const alicia = await registerAndWatch(member, memberDir, "alicia", loopbackTcpDesignator(port));

		const asker = await dial(loopbackTcpDesignator(port));
		asker.serve().catch(() => {});
		const askerDir = await asker.fetch(DIRECTORY);
		await registerAndWatch(asker, askerDir, "dave", "127.0.0.1:1");

		const stale = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["alice", alice.registrationId]));
		assert(stale === PEER_OFFLINE, `the given-up name should be gone, got ${stale}`);
		const live = await refusalCode(() => asker.send(askerDir, INTRODUCE, ["alicia", alicia.registrationId]));
		assert(live === INTRODUCTION_PENDING, `the held name should answer, got ${live}`);

		asker.close();
		member.close();
		await Promise.allSettled([
			asker.serve().catch(() => {}),
			member.serve().catch(() => {}),
		]);
	});
});

roomsTest("rooms directory refuses a nick another live connection holds", async () => {
	await withServer(async (port) => {
		const designator = loopbackTcpDesignator(port);

		const first = await dial(loopbackTcpDesignator(port));
		first.serve().catch(() => {});
		const firstDir = await first.fetch(DIRECTORY);
		let firstAck = false;
		const firstInbox = first.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") firstAck = true;
			return null;
		});
		await first.send(firstDir, REGISTER, ["bot", designator, firstInbox]);
		const firstDeadline = Date.now() + 3_000;
		while (!firstAck && Date.now() < firstDeadline) await delay(25);
		assert(firstAck, "first registrar should receive notify(registered)");

		// Another connection asking for the same name is refused while the holder's
		// connection is open. A registration is what `introduce` routes on, so
		// granting this would hand callers the wrong member's capability.
		const second = await dial(loopbackTcpDesignator(port));
		second.serve().catch(() => {});
		const secondDir = await second.fetch(DIRECTORY);
		const secondInbox = second.spawn(() => null);
		let refused: string | null = null;
		try {
			await second.send(secondDir, REGISTER, ["bot", designator, secondInbox]);
		} catch (err) {
			refused = err instanceof Error ? err.message : String(err);
		}
		assert(refused !== null, "a second connection should be refused the held nick");
		assert(
			RoomError.from(refused)?.code === NICK_TAKEN,
			`expected nick-taken, got ${refused}`,
		);

		// A refresh of its own claim must not free the name in the middle of
		// itself. Fire the refresh and a rival's attempt together, so the rival
		// lands while the refresh is still awaiting its fetch: releasing the name
		// first made that window real, and the guard sees no holder inside it.
		const refresh = first.send(firstDir, REGISTER, ["bot", designator, firstInbox]);
		let racedIn: string | null = null;
		try {
			await second.send(secondDir, REGISTER, ["bot", designator, secondInbox]);
			racedIn = "granted";
		} catch {
			racedIn = null;
		}
		await refresh;
		assert(racedIn === null, "a rival must not slip in while the holder refreshes its claim");

		// And the name frees when its holder's connection ends.
		first.close();
		await first.serve().catch(() => {});
		let secondAck = false;
		const ackInbox = second.spawn((verb, args) => {
			if (verb === NOTIFY && args[0] === "registered") secondAck = true;
			return null;
		});
		const freeDeadline = Date.now() + 5_000;
		while (!secondAck && Date.now() < freeDeadline) {
			await second.send(secondDir, REGISTER, ["bot", designator, ackInbox]).catch(() => {});
			await delay(100);
		}
		assert(secondAck, "the nick should free once its holder's connection is gone");

		second.close();
		await second.serve().catch(() => {});
	});
});
