import { type Behavior, parseSturdyRef, type Session } from "@pancake/runtime";
import { RoomsSessionClient, type RoomsSessionLineEvent } from "../lib/rooms_session.ts";
import {
	dial as dialRooms,
	loopbackTcpDesignator,
	roomsAddress,
	roomsHost,
	roomsListen,
	roomsLocator,
	roomsSturdyrefForSession,
} from "../lib/locator.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { DirectMessage, Directory, Room } from "../lib/room_client.ts";
import { enterOrOpen } from "../lib/enter_room.ts";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { DM, TYPING } from "../lib/protocol.ts";
import { directReceivedLineBehavior } from "../session/direct_line.ts";
import { type Attachment, fetchBlob } from "../lib/attachment.ts";
import { stopOwned } from "./support/children.ts";
import {
	assert,
	dial,
	freePort,
	readPort,
	roomsTest,
	startStatefulServer,
	stopServer,
	within,
} from "./support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "./support/standalone_peer.ts";

roomsTest("a durable session and an ordinary member share one bidirectional direct line", async () => {
	const serverState = await Deno.makeTempDir({ prefix: "pancake-rooms-mixed-dm-server-" });
	const aliceState = await Deno.makeTempDir({ prefix: "pancake-rooms-mixed-dm-alice-" });
	const roomPort = freePort();
	const alicePort = freePort();
	const server = startStatefulServer(roomPort, serverState);
	let alicePeer: Deno.ChildProcess | null = null;
	const bobHost = roomsHost();
	const bobEndpoint = await roomsListen("127.0.0.1", 0, bobHost);
	const bobAccepting = (async () => {
		for await (const session of bobEndpoint) void session.serve().catch(() => {});
	})();
	const bobRuntime = await openRoomsRuntime({ host: bobHost });
	let bobDirectory: Directory | null = null;
	let bobLine: DirectMessage | null = null;
	let bobRoom: Room | null = null;
	try {
		await readPort(server);
		const locator = loopbackTcpDesignator(roomPort);
		const directory = roomsPeerAuthority(roomsLocator(locator));
		const bobDir = await Directory.connect(locator, (address) => dialRooms(address, bobRuntime));
		bobDirectory = bobDir;
		const publicMessages: string[] = [];
		const publicTyping: boolean[] = [];
		const offerer = inboxPublisher(bobHost).offerer({
			dir: () => bobDir,
			behaviorFor: (_peer): Behavior => (verb, args) => {
				if (verb === TYPING) {
					publicTyping.push(args[0] === true);
					return null;
				}
				if (verb === DM) {
					publicMessages.push(typeof args[0] === "string" ? args[0] : "");
					return null;
				}
				throw new Error(`Bob's mixed direct inbox has no method ${verb}`);
			},
		});
		const bobClaim = await bobDir.register("bob", loopbackTcpDesignator(bobEndpoint.port), offerer.offer);
		await Deno.writeTextFile(
			`${aliceState}/checkpoint.json`,
			JSON.stringify({
				...emptyRoomsSessionState(),
				directories: [{ id: directory, locator, home: true, nick: "alice", standing: null }],
				conversations: [{
					kind: "direct",
					id: "alice-bob",
					directory,
					peer: "bob",
					peerRegistrationId: bobClaim,
					closed: false,
					draft: "",
				}],
			}),
		);
		alicePeer = startRoomsSessionPeer(aliceState, alicePort, `${aliceState}/checkpoint.json`);
		const aliceLink = await announcedSturdyref(alicePeer, "ROOMS-SESSION-LISTENING", "Alice session peer");
		const parsed = parseSturdyRef(aliceLink, "v1_0");
		const aliceSession = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
		const alice = new RoomsSessionClient(
			aliceSession,
			await aliceSession.enliven(roomsSturdyrefForSession(aliceLink, aliceSession)),
		);
		try {
			const stage = async <T>(label: string, work: Promise<T>): Promise<T> => {
				try {
					return await work;
				} catch (error) {
					throw new Error(`${label}: ${error instanceof Error ? error.message : String(error)}`, {
						cause: error,
					});
				}
			};
			const aliceReceived = Promise.withResolvers<string>();
			const aliceReceivedSecond = Promise.withResolvers<string>();
			const aliceSawEdit = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceReceivedAfterReopen = Promise.withResolvers<string>();
			const aliceSawTypingOn = Promise.withResolvers<boolean>();
			const aliceSawTypingOff = Promise.withResolvers<boolean>();
			const aliceSawWithdraw = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceSent = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceSawOrdinaryFile = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceSawOrdinaryRefile = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceSentFile = Promise.withResolvers<RoomsSessionLineEvent>();
			const aliceLines: RoomsSessionLineEvent[] = [];
			await alice.watch(() => {}, (event) => {
				if (event.conversationId !== "alice-bob") return;
				if (event.presence?.kind === "typing") {
					(event.presence.on ? aliceSawTypingOn : aliceSawTypingOff).resolve(event.presence.on);
				} else if (event.change === "edited" && event.text === "ordinary first line edited") {
					aliceSawEdit.resolve(event);
				} else if (event.change === "refiled" && event.text === "ordinary file replaced") {
					aliceSawOrdinaryRefile.resolve(event);
				} else if (event.change === "withdrawn") {
					aliceSawWithdraw.resolve(event);
				} else if (event.text === "ordinary file") {
					aliceSawOrdinaryFile.resolve(event);
				} else if (event.text === "durable file") {
					aliceSentFile.resolve(event);
				} else if (event.text === "durable session replied") {
					aliceSent.resolve(event);
				} else if (event.text === "ordinary member sent another line") {
					aliceLines.push(event);
					aliceReceivedSecond.resolve(event.text);
				} else if (event.text === "ordinary member reopened the direct line") {
					aliceReceivedAfterReopen.resolve(event.text);
				} else if (event.text !== "") {
					aliceLines.push(event);
					aliceReceived.resolve(event.text);
				}
			});
			const directIssue = `direct:${directory}:alice-bob`;
			const bobReplies: string[] = [];
			const bobSawTypingOn = Promise.withResolvers<boolean>();
			const bobSawTypingOff = Promise.withResolvers<boolean>();
			const bobSawEdit = Promise.withResolvers<string>();
			const bobSawWithdraw = Promise.withResolvers<boolean>();
			const bobSawFile = Promise.withResolvers<{ attachments: Attachment[]; session: Session }>();
			const bobSawRefile = Promise.withResolvers<{ attachments: Attachment[]; session: Session }>();
			const bobSawArchive = Promise.withResolvers<{ directory: string; conversation: string }>();
			const bobSawRoomOffer = Promise.withResolvers<{ label: string; link: string }>();
			let bobLineId = 0;
			const openBobLine = async (): Promise<DirectMessage> => {
				let lastOpenError: unknown = null;
				for (let attempt = 0; attempt < 40; attempt += 1) {
					try {
						return await DirectMessage.open(
							bobDir,
							"alice",
							{
								message: (text, attachments, session) => {
									bobReplies.push(text);
									if (text === "durable file") bobSawFile.resolve({ attachments, session });
									bobLineId += 1;
									return session.spawn(
										directReceivedLineBehavior("alice", bobLineId, attachments, (message) => {
											if (message.change === "edited") bobSawEdit.resolve(message.text);
											if (message.change === "withdrawn") bobSawWithdraw.resolve(true);
											if (message.change === "refiled") {
												bobSawRefile.resolve({ attachments: message.attachments, session });
											}
										}),
									);
								},
								typing: (on) => (on ? bobSawTypingOn : bobSawTypingOff).resolve(on),
								handArchive: (directoryId, conversation) => {
									bobSawArchive.resolve({ directory: directoryId, conversation });
								},
								offerRoom: (label, link) => bobSawRoomOffer.resolve({ label, link }),
							},
						);
					} catch (error) {
						lastOpenError = error;
						await new Promise((resolve) => setTimeout(resolve, 100));
					}
				}
				throw lastOpenError ?? new Error("Bob could not open Alice's durable direct line");
			};
			bobLine = await openBobLine();
			const first = await bobLine.say("ordinary member opened the direct line");
			assert(
				await within(aliceReceived.promise, "the ordinary-to-durable direct message") ===
					"ordinary member opened the direct line",
				"the durable session did not receive the ordinary member's direct message",
			);
			const second = await bobLine.say("ordinary member sent another line");
			assert(
				await within(aliceReceivedSecond.promise, "the second ordinary-to-durable direct message") ===
					"ordinary member sent another line",
				"the second mixed direct message did not arrive",
			);
			assert(first != null && second != null, "the durable receiver did not return direct-line authority");
			assert(
				aliceLines.length === 2 && aliceLines[0].lineId != null && aliceLines[1].lineId != null &&
					aliceLines[0].history != null && aliceLines[1].history != null &&
					aliceLines[0].lineId !== aliceLines[1].lineId &&
					aliceLines[0].history.id !== aliceLines[1].history.id,
				"repeated messages on one reply route reused a line or archive identity",
			);
			await first.edit("ordinary first line edited");
			const edited = await within(aliceSawEdit.promise, "the first mixed direct-line edit");
			assert(
				edited.lineId === aliceLines[0].lineId,
				"editing the first mixed direct line changed another message",
			);
			await second.withdraw();
			const withdrawn = await within(aliceSawWithdraw.promise, "the second mixed direct-line withdrawal");
			assert(
				withdrawn.lineId === aliceLines[1].lineId,
				"withdrawing the second mixed direct line changed another message",
			);
			first.release();
			second.release();
			const ordinaryFileLine = await bobLine.sendFiles([{
				name: "ordinary.txt",
				mime: "text/plain",
				bytes: new TextEncoder().encode("ordinary bytes"),
			}], "ordinary file");
			const ordinaryFile = await within(aliceSawOrdinaryFile.promise, "the ordinary-origin mixed file");
			assert(ordinaryFile.attachments.length === 1, "the shared session dropped the ordinary file capability");
			const ordinaryBytes = await alice.fetchAttachment(ordinaryFile.attachments[0]);
			alice.releaseAttachment(ordinaryFile.attachments[0]);
			assert(new TextDecoder().decode(ordinaryBytes) === "ordinary bytes", "the ordinary file bytes changed");
			assert(ordinaryFileLine != null, "the shared receiver did not return authority for the ordinary file line");
			await ordinaryFileLine.refile("ordinary file replaced", [], [{
				name: "ordinary-replacement.txt",
				mime: "text/plain",
				bytes: new TextEncoder().encode("ordinary replacement bytes"),
			}]);
			const ordinaryRefile = await within(aliceSawOrdinaryRefile.promise, "the ordinary-origin mixed refile");
			assert(ordinaryRefile.attachments.length === 1, "the shared session dropped the replacement file");
			const ordinaryReplacement = await alice.fetchAttachment(ordinaryRefile.attachments[0]);
			alice.releaseAttachment(ordinaryRefile.attachments[0]);
			assert(
				new TextDecoder().decode(ordinaryReplacement) === "ordinary replacement bytes",
				"the ordinary replacement bytes changed",
			);
			ordinaryFileLine.release();
			assert(
				!(await alice.snapshot()).issues.some((issue) => issue.subject === directIssue),
				"the adopted incoming route left the durable direct conversation unavailable",
			);

			await alice.setTyping("alice-bob", true);
			assert(
				await within(bobSawTypingOn.promise, "durable-to-ordinary typing") === true,
				"the ordinary member did not receive the durable session's typing level",
			);
			await alice.setTyping("alice-bob", false);
			assert(
				await within(bobSawTypingOff.promise, "durable-to-ordinary typing stop") === false,
				"the ordinary member did not receive the durable session's stopped typing level",
			);
			await bobLine.typing(true);
			assert(
				await within(aliceSawTypingOn.promise, "ordinary-to-durable typing") === true,
				"the durable session did not receive the ordinary member's typing level",
			);
			await bobLine.typing(false);
			assert(
				await within(aliceSawTypingOff.promise, "ordinary-to-durable typing stop") === false,
				"the durable session did not receive the ordinary member's stopped typing level",
			);

			const revision = (await alice.snapshot()).revision;
			await alice.say("mixed-dm-reply", revision, "alice-bob", "durable session replied");
			const durableLine = await within(aliceSent.promise, "the durable-origin mixed direct line");
			assert(
				durableLine.lineId != null && durableLine.editable,
				"the mixed direct reply lost mutation authority",
			);
			const replyDeadline = Date.now() + 5_000;
			while (!bobReplies.includes("durable session replied") && Date.now() < replyDeadline) {
				await new Promise((resolve) => setTimeout(resolve, 25));
			}
			assert(bobReplies.includes("durable session replied"), "the durable session's direct reply did not arrive");
			await alice.editLine("mixed-dm-edit", revision, "alice-bob", durableLine.lineId, "durable reply edited");
			assert(
				await within(bobSawEdit.promise, "the durable-origin mixed direct edit") === "durable reply edited",
				"the durable session's direct edit changed or missed the ordinary line",
			);
			await alice.withdrawLine("mixed-dm-withdraw", revision, "alice-bob", durableLine.lineId);
			assert(
				await within(bobSawWithdraw.promise, "the durable-origin mixed direct withdrawal"),
				"the durable session's direct withdrawal missed the ordinary line",
			);
			await alice.sendFiles("mixed-dm-file", revision, "alice-bob", "durable file", [{
				name: "durable.txt",
				mime: "text/plain",
				bytes: new TextEncoder().encode("durable bytes"),
			}]);
			const durableFile = await within(aliceSentFile.promise, "the durable-origin mixed file");
			assert(durableFile.lineId != null, "the durable file line had no mutation identity");
			const bobFile = await within(bobSawFile.promise, "the ordinary receiver's durable file");
			assert(bobFile.attachments.length === 1, "the ordinary receiver dropped the durable file capability");
			const durableBytes = await fetchBlob(bobFile.session, bobFile.attachments[0]);
			bobFile.session.release(bobFile.attachments[0].blob);
			assert(new TextDecoder().decode(durableBytes) === "durable bytes", "the durable file bytes changed");
			await alice.refileLine(
				"mixed-dm-refile",
				revision,
				"alice-bob",
				durableFile.lineId,
				"durable file replaced",
				[],
				[{
					name: "durable-replacement.txt",
					mime: "text/plain",
					bytes: new TextEncoder().encode("durable replacement bytes"),
				}],
			);
			const bobRefile = await within(bobSawRefile.promise, "the ordinary receiver's durable refile");
			assert(bobRefile.attachments.length === 1, "the ordinary receiver dropped the durable replacement");
			const durableReplacement = await fetchBlob(bobRefile.session, bobRefile.attachments[0]);
			bobRefile.session.release(bobRefile.attachments[0].blob);
			assert(
				new TextDecoder().decode(durableReplacement) === "durable replacement bytes",
				"the durable replacement bytes changed",
			);
			const historySnapshot = await alice.snapshot();
			const history = (await alice.readHistory("direct", directory, "alice-bob"))
				.filter((record) => record.kind === "line");
			const historyText = history.map((record) => record.text);
			assert(
				historyText.includes("ordinary first line edited") &&
					historyText.includes("ordinary file replaced") &&
					historyText.includes("durable file replaced"),
				`mixed direct history lost an edited or refiled line: ${
					JSON.stringify({
						rows: history.map((record) => ({
							text: record.text,
							state: record.state,
							files: record.attachments.length,
						})),
						issues: historySnapshot.issues,
					})
				}`,
			);
			assert(
				!historyText.includes("ordinary member sent another line") &&
					!historyText.includes("durable session replied"),
				"mixed direct history retained a withdrawn line",
			);
			assert(
				new Set(history.map((record) => `${record.source}\u0000${record.generation}\u0000${record.id}`))
					.size ===
					history.length,
				"mixed direct history reused a durable record identity",
			);
			bobRoom = await Room.subscribe(bobDir.session, await enterOrOpen(bobDir, "mixed-offer"), "bob");
			const roomLink = await stage("minting the ordinary room link", bobRoom.link());
			await stage(`offering the ordinary room link ${roomLink}`, bobLine.offerRoom("mixed offer", roomLink));
			const offered = await alice.snapshot();
			const invitation = offered.checkpoint.invitations.find((entry) => entry.link === roomLink);
			assert(invitation != null, "the ordinary member's durable room offer did not enter the shared session");
			const acceptedRevision = await stage(
				"accepting the mixed room offer",
				alice.acceptInvitation(
					"mixed-dm-accept-room",
					offered.revision,
					invitation.id,
					"mixed-offered-room",
				),
			);
			await stage(
				"offering the mixed room back",
				alice.offerRoom(
					"mixed-dm-offer-room",
					acceptedRevision,
					"mixed-offered-room",
					"alice-bob",
				),
			);
			assert(
				JSON.stringify(await within(bobSawRoomOffer.promise, "durable-to-ordinary room offering")) ===
					JSON.stringify({ label: "mixed offer", link: roomLink }),
				"the shared session's room offer did not use the adopted direct route",
			);
			await alice.shareArchiveHistory("alice-bob");
			assert(
				JSON.stringify(await within(bobSawArchive.promise, "durable-to-ordinary archive sharing")) ===
					JSON.stringify({ directory, conversation: "alice-bob" }),
				"the durable session's archive share did not use the adopted direct route",
			);
			assert(publicMessages.length === 0, "the adopted reply route was bypassed by a second direct path");
			assert(publicTyping.length === 0, "typing bypassed the adopted reply route");

			await bobLine.close();
			bobLine = await openBobLine();
			const reopened = await bobLine.say("ordinary member reopened the direct line");
			reopened?.release();
			assert(
				await within(aliceReceivedAfterReopen.promise, "the reopened mixed direct line") ===
					"ordinary member reopened the direct line",
				"the durable session did not adopt the replacement direct route",
			);

			await bobLine.close();
			bobLine = null;
			await stopOwned(alicePeer);
			alicePeer = null;
			await aliceSession.close().catch(() => {});
			alicePeer = startRoomsSessionPeer(aliceState, alicePort);
			const restoredLink = await announcedSturdyref(
				alicePeer,
				"ROOMS-SESSION-LISTENING",
				"restored Alice session peer",
			);
			assert(restoredLink === aliceLink, "restart changed the durable mixed-session capability");
			const restoredConnection = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "v1-syrup"));
			try {
				const restoredAlice = new RoomsSessionClient(
					restoredConnection,
					await restoredConnection.enliven(roomsSturdyrefForSession(restoredLink, restoredConnection)),
				);
				const restoredReceived = Promise.withResolvers<string>();
				const restoredSent = Promise.withResolvers<RoomsSessionLineEvent>();
				await restoredAlice.watch(() => {}, (event) => {
					if (event.conversationId !== "alice-bob") return;
					if (event.text === "ordinary member reached the restored session") {
						restoredReceived.resolve(event.text);
					}
					if (event.text === "restored durable session replied") restoredSent.resolve(event);
				});
				bobLine = await openBobLine();
				const afterRestart = await bobLine.say("ordinary member reached the restored session");
				afterRestart?.release();
				assert(
					await within(restoredReceived.promise, "the ordinary message after durable restart") ===
						"ordinary member reached the restored session",
					"the restored durable session did not adopt the ordinary member's new route",
				);
				const restoredSnapshot = await restoredAlice.snapshot();
				assert(
					!restoredSnapshot.issues.some((issue) => issue.subject === directIssue),
					"the restored incoming route left the mixed direct conversation unavailable",
				);
				await restoredAlice.say(
					"mixed-dm-after-restart",
					restoredSnapshot.revision,
					"alice-bob",
					"restored durable session replied",
				);
				const restoredOwned = await within(restoredSent.promise, "the durable reply after restart");
				assert(
					restoredOwned.lineId != null && restoredOwned.editable,
					"the restored mixed direct reply lost its mutation authority",
				);
				const restoredReplyDeadline = Date.now() + 5_000;
				while (!bobReplies.includes("restored durable session replied") && Date.now() < restoredReplyDeadline) {
					await new Promise((resolve) => setTimeout(resolve, 25));
				}
				assert(
					bobReplies.includes("restored durable session replied"),
					"the ordinary member did not receive the restored durable session's reply",
				);
				const restoredHistory = (await restoredAlice.readHistory("direct", directory, "alice-bob"))
					.filter((record) => record.kind === "line");
				assert(
					restoredHistory.some((record) => record.text === "ordinary first line edited") &&
						restoredHistory.some((record) => record.text === "restored durable session replied"),
					"restart lost either the prior or resumed mixed direct history",
				);
				const archivedFile = restoredHistory.find((record) => record.text === "ordinary file replaced");
				assert(
					archivedFile?.attachments[0]?.blob != null,
					"restart lost the ordinary member's archived file custody",
				);
				const archivedBytes = await restoredAlice.fetchArchivedAttachment(archivedFile, 0);
				assert(
					new TextDecoder().decode(archivedBytes) === "ordinary replacement bytes",
					"restart changed the ordinary member's archived file bytes",
				);
				await bobLine?.close();
				bobLine = null;
				const replacementClaim = await bobDir.register(
					"bob",
					loopbackTcpDesignator(bobEndpoint.port),
					offerer.offer,
				);
				assert(replacementClaim !== bobClaim, "a replacement Bob reused the prior registration claim");
				await new Promise((resolve) => setTimeout(resolve, 100));
				const beforeRetarget = publicMessages.length;
				let retargetRefusal = "";
				try {
					const current = await restoredAlice.snapshot();
					await restoredAlice.say(
						"mixed-dm-stale-claim",
						current.revision,
						"alice-bob",
						"must not reach replacement Bob",
					);
				} catch (error) {
					retargetRefusal = error instanceof Error ? error.message : String(error);
				}
				assert(retargetRefusal !== "", "the durable conversation silently retargeted a reused nickname");
				assert(
					publicMessages.length === beforeRetarget,
					"the replacement nickname holder received old-thread traffic",
				);
			} finally {
				await restoredConnection.close();
			}
		} finally {
			await aliceSession.close().catch(() => {});
			await offerer.close();
		}
	} finally {
		await bobLine?.close().catch(() => {});
		await bobRoom?.leave().catch(() => {});
		await bobDirectory?.close().catch(() => {});
		bobEndpoint.close();
		await bobAccepting.catch(() => {});
		await bobRuntime.close();
		if (alicePeer != null) await stopOwned(alicePeer);
		await stopServer(server);
		await Deno.remove(serverState, { recursive: true });
		await Deno.remove(aliceState, { recursive: true });
	}
});
