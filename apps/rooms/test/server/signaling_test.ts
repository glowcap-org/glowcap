// Bringing up a channel between two members who cannot dial each other.
//
// The directory carries the offer, the answer, and the candidates, and parses
// none of them: they are opaque strings routed by the same registry that holds
// the names, which is the only reason this is the directory's business at all.
// What is tested is the routing and its bounds — who may answer an exchange,
// how many may be open, and what happens to the oldest when that fills.

// Names, and the introductions that turn one into a direct line.
//
// A nickname is a claim on a name held by a connection, so most of these are
// about the moments when two claims meet: a second connection presenting proof,
// a name freed and asked for again, a registration replaced. The signaling that
// brings up a channel between two members lives here too, because it is routed
// by the same registry that holds the names.
import { MAX_SIGNAL_EXCHANGES, MAX_SIGNAL_SDP } from "../../lib/limits.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import {
	DIRECTORY,
	OFFER_SIGNALING,
	REGISTER,
	SIG_ACCEPTED,
	SIG_ANSWER,
	SIG_CANDIDATE,
	SIG_OFFER,
	SIG_REJECT,
	SIGNAL_ANSWER,
	SIGNAL_DONE,
	SIGNAL_OFFER,
} from "../../lib/protocol.ts";
import { Directory } from "../../lib/room/client.ts";
import {
	assert,
	assertMatch,
	delay,
	dial,
	registerAndWatch,
	roomsTest,
	until,
	withServer,
} from "../support/rooms_server.ts";
import { Session } from "@pancake/runtime";

roomsTest("a webrtc designator held by a live registration is not overwritable", async () => {
	// A `signalOffer` routes by designator, so whoever the table names receives
	// every DM bring-up aimed at that identity. An unkeyed connection's claim
	// cannot be verified, but a claim to a designator another live registration
	// already routes by can be refused without any keys — accepting it
	// overwrote the holder's row and redirected their calls to the claimant.
	await withServer(async (port) => {
		const alice = await dial(loopbackTcpDesignator(port));
		alice.serve().catch(() => {});
		const mallory = await dial(loopbackTcpDesignator(port));
		mallory.serve().catch(() => {});
		try {
			const aliceDir = await alice.fetch(DIRECTORY);
			const malloryDir = await mallory.fetch(DIRECTORY);
			const designator = "ocapn://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.webrtc";
			await alice.send(aliceDir, REGISTER, ["alice", designator, alice.spawn(() => null)]);
			let refused = "";
			try {
				await mallory.send(malloryDir, REGISTER, ["mallory", designator, mallory.spawn(() => null)]);
			} catch (err) {
				refused = err instanceof Error ? err.message : String(err);
			}
			assertMatch(refused, /already registered to "alice"/);
			// The same member re-registering keeps their own designator: the
			// refusal is about another holder, not about re-claiming your own.
			await alice.send(aliceDir, REGISTER, ["alice", designator, alice.spawn(() => null)]);
		} finally {
			alice.close();
			mallory.close();
			await alice.serve().catch(() => {});
			await mallory.serve().catch(() => {});
		}
	});
});

roomsTest(
	"rooms signaling admits an offer before early ICE and rejects a second active dial",
	async () => {
		await withServer(async (port) => {
			const locator = loopbackTcpDesignator(port);
			const targetDesignator = "11".repeat(32);
			const targetLocator = `ocapn://${targetDesignator}.webrtc`;
			const origin = await Directory.connect(locator, (address) => dial(address));
			const target = await Directory.connect(locator, (address) => dial(address));
			try {
				await origin.register("signal-origin", locator);
				await target.register("signal-target", targetLocator);

				const targetEvents: string[] = [];
				const signalingInbox = target.session.spawn((verb, args) => {
					const id = typeof args[0] === "string" ? args[0] : "";
					if (verb === SIG_OFFER) {
						targetEvents.push(`offer:${id}`);
						void target.signalAnswer(id, "answer-sdp");
					} else if (verb === SIG_CANDIDATE) {
						targetEvents.push(`candidate:${id}:${String(args[1] ?? "")}`);
					}
					return null;
				});
				await target.offerSignaling(signalingInbox);

				const dispose = origin.onSignalCandidate(targetDesignator, () => {});
				let earlySettled = false;
				const early = origin.signalCandidate(targetDesignator, "early-ice").then(() => {
					earlySettled = true;
				});
				await delay(25);
				assert(!earlySettled, "an ICE candidate crossed before its exchange was admitted");

				assert(
					await origin.signalOffer(targetDesignator, "offer-sdp") === "answer-sdp",
					"the admitted signaling offer should receive its answer",
				);
				await early;
				await until(
					() => targetEvents.some((event) => event.endsWith(":early-ice")),
					"the early ICE candidate never reached the admitted exchange",
				);
				assert(
					targetEvents[0]?.startsWith("offer:"),
					`candidate arrived before offer: ${JSON.stringify(targetEvents)}`,
				);

				let duplicate = "";
				try {
					await origin.signalOffer(targetDesignator, "second-offer");
				} catch (error) {
					duplicate = error instanceof Error ? error.message : String(error);
				}
				assertMatch(duplicate, /already active/);
				dispose();
			} finally {
				await Promise.allSettled([origin.close(), target.close()]);
			}
		});
	},
);

roomsTest(
	"rooms signaling rejects a replaced exchange and stale retirement cannot close its successor",
	async () => {
		await withServer(async (port) => {
			const locator = loopbackTcpDesignator(port);
			const targetDesignator = "22".repeat(32);
			const targetLocator = `ocapn://${targetDesignator}.webrtc`;
			const origin = await dial(locator);
			const target = await dial(locator);
			origin.serve().catch(() => {});
			target.serve().catch(() => {});
			try {
				const originDirectory = await origin.fetch(DIRECTORY);
				const targetDirectory = await target.fetch(DIRECTORY);
				await registerAndWatch(origin, originDirectory, "raw-origin", locator);
				await registerAndWatch(target, targetDirectory, "raw-target", targetLocator);

				const offers: string[] = [];
				const signalingInbox = target.spawn((verb, args) => {
					if (verb === SIG_OFFER && typeof args[0] === "string") offers.push(args[0]);
					return null;
				});
				await target.send(targetDirectory, OFFER_SIGNALING, [signalingInbox]);

				const firstAccepted: string[] = [];
				const firstRejected: string[] = [];
				const firstReply = origin.spawn((verb, args) => {
					if (verb === SIG_ACCEPTED && typeof args[0] === "string") {
						firstAccepted.push(args[0]);
					}
					if (verb === SIG_REJECT) firstRejected.push(String(args[0] ?? ""));
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					targetDesignator,
					"first-offer",
					firstReply,
				]);
				await until(() => firstAccepted.length === 1, "first exchange was not admitted");
				assert(
					offers.includes(firstAccepted[0]),
					"an accepted exchange had not delivered its offer",
				);

				const secondAccepted: string[] = [];
				const secondAnswers: string[] = [];
				const secondReply = origin.spawn((verb, args) => {
					if (verb === SIG_ACCEPTED && typeof args[0] === "string") {
						secondAccepted.push(args[0]);
					}
					if (verb === SIG_ANSWER && typeof args[0] === "string") {
						secondAnswers.push(args[0]);
					}
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					targetDesignator,
					"second-offer",
					secondReply,
				]);
				await until(
					() => secondAccepted.length === 1,
					"replacement exchange was not admitted",
				);
				await until(
					() => firstRejected.length === 1,
					"replaced exchange did not reject its caller",
				);
				assertMatch(firstRejected[0], /replaced/);

				const firstId = firstAccepted[0];
				const secondId = secondAccepted[0];
				assert(firstId !== secondId, "replacement reused an exchange identity");
				await origin.tell(originDirectory, SIGNAL_DONE, [firstId]);
				await target.tell(targetDirectory, SIGNAL_ANSWER, [secondId, "second-answer"]);
				await until(
					() => secondAnswers[0] === "second-answer",
					"stale retirement closed the replacement exchange",
				);
				await origin.tell(originDirectory, SIGNAL_DONE, [secondId]);
				assert(
					offers.includes(firstId) && offers.includes(secondId),
					"target did not receive both offers",
				);
			} finally {
				origin.close();
				target.close();
				await Promise.allSettled([
					origin.serve().catch(() => {}),
					target.serve().catch(() => {}),
				]);
			}
		});
	},
);

roomsTest("the directory will not carry a bring-up larger than a bring-up", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const origin = await dial(locator);
		const originServed = origin.serve().catch(() => {});
		const target = await dial(locator);
		const targetServed = target.serve().catch(() => {});
		try {
			const originDirectory = await origin.fetch(DIRECTORY);
			await registerAndWatch(origin, originDirectory, "shouting-origin", locator);
			const targetDirectory = await target.fetch(DIRECTORY);
			const designator = "f".repeat(64);
			await registerAndWatch(target, targetDirectory, "shouted-at", `ocapn://${designator}.webrtc`);
			await target.send(targetDirectory, OFFER_SIGNALING, [target.spawn(() => null)]);

			// The room carries the offer bytes exactly as they arrive, so the relay
			// bound is the room's to enforce before it forwards them to another member.
			let refused = "";
			await origin.send(originDirectory, SIGNAL_OFFER, [
				designator,
				"v=0".repeat(MAX_SIGNAL_SDP),
				origin.spawn(() => null),
			]).catch((err) => {
				refused = err instanceof Error ? err.message : String(err);
			});
			assert(refused !== "", "the directory took an offer larger than a bring-up and passed it on");

			// A bring-up of an ordinary size still goes through, so the bound refuses
			// the right side of itself.
			const accepted: string[] = [];
			const reply = origin.spawn((verb, args) => {
				if (verb === SIG_ACCEPTED) accepted.push(String(args[0] ?? ""));
				return null;
			});
			await origin.send(originDirectory, SIGNAL_OFFER, [designator, "v=0\r\no=- 1 1 IN IP4 0.0.0.0", reply]);
			await until(() => accepted.length === 1, "an ordinary offer was not admitted");
		} finally {
			origin.close();
			target.close();
			await Promise.allSettled([originServed, targetServed]);
		}
	});
});

roomsTest("rooms signaling evicts the oldest bounded exchange and rejects its caller", async () => {
	await withServer(async (port) => {
		const locator = loopbackTcpDesignator(port);
		const origin = await dial(locator);
		const originServed = origin.serve().catch(() => {});
		const targets: { session: Session; served: Promise<void>; designator: string }[] = [];
		try {
			const originDirectory = await origin.fetch(DIRECTORY);
			await registerAndWatch(origin, originDirectory, "eviction-origin", locator);

			const setupTargets = Array.from(
				{ length: MAX_SIGNAL_EXCHANGES + 1 },
				async (_, index) => {
					const session = await dial(locator);
					const served = session.serve().catch(() => {});
					const directory = await session.fetch(DIRECTORY);
					const designator = (index + 1).toString(16).padStart(64, "0");
					await registerAndWatch(
						session,
						directory,
						`eviction-target-${index}`,
						`ocapn://${designator}.webrtc`,
					);
					await session.send(directory, OFFER_SIGNALING, [session.spawn(() => null)]);
					return { session, served, designator };
				},
			);
			targets.push(...await Promise.all(setupTargets));

			const firstRejected: string[] = [];
			for (const [index, target] of targets.entries()) {
				const reply = origin.spawn((verb, args) => {
					if (index === 0 && verb === SIG_REJECT) {
						firstRejected.push(String(args[0] ?? ""));
					}
					return null;
				});
				await origin.send(originDirectory, SIGNAL_OFFER, [
					target.designator,
					`offer-${index}`,
					reply,
				]);
			}
			await until(() => firstRejected.length === 1, "oldest exchange was not evicted");
			assertMatch(firstRejected[0], /evicted/);
		} finally {
			origin.close();
			for (const target of targets) target.session.close();
			await Promise.allSettled([originServed, ...targets.map((target) => target.served)]);
		}
	});
});
