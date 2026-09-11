// A durable Rooms session peer given a saved directory with no member name
// still connects it for scoped capabilities, without registering a member.
//
// Split from session_peer_test.ts by subject: that file keeps the retry-at-
// startup and revisioned-state scenarios; this one holds the unnamed
// directory alone, which is its own contract.

import { parseSturdyRef } from "@glowcap/runtime";
import { RoomsSessionClient } from "../../lib/session/client.ts";
import { loopbackTcpDesignator, roomsAddress, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { roomsPeerAuthority } from "../../lib/routes.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { stopOwned } from "../support/children.ts";
import {
	assert,
	dial,
	freePort,
	readPort,
	roomsTest,
	startStatefulServer,
	stopServer,
	within,
} from "../support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "../support/standalone_peer.ts";

roomsTest("an unnamed saved directory connects for scoped capabilities without registering a member", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-unnamed-" });
	const roomDirectory = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-unnamed-room-" });
	const peerPort = freePort();
	const roomPort = freePort();
	const roomServer = startStatefulServer(roomPort, roomDirectory, [
		"--operator",
		"--admin-listeners",
		"--diagnostics",
		"--irc",
	]);
	try {
		await readPort(roomServer);
		const roomLocator = loopbackTcpDesignator(roomPort);
		const roomDirectoryId = roomsPeerAuthority(roomsLocator(roomLocator));
		const operatorSwiss = (await Deno.readTextFile(`${roomDirectory}/operator`)).trim();
		const listenersSwiss = (await Deno.readTextFile(`${roomDirectory}/admin-listeners`)).trim();
		const diagnosticsSwiss = (await Deno.readTextFile(`${roomDirectory}/diagnostics`)).trim();
		const ircSwiss = (await Deno.readTextFile(`${roomDirectory}/irc`)).trim();
		const checkpointPath = `${directory}/checkpoint.json`;
		await Deno.writeTextFile(
			checkpointPath,
			JSON.stringify({
				...emptyRoomsSessionState(),
				directories: [{ id: roomDirectoryId, locator: roomLocator, home: true, nick: "", standing: null }],
				capabilities: {
					operations: [
						{ capability: "operator", scope: roomDirectoryId, swiss: operatorSwiss },
						{ capability: "listeners", scope: roomDirectoryId, swiss: listenersSwiss },
						{ capability: "diagnostics", scope: roomDirectoryId, swiss: diagnosticsSwiss },
						{ capability: "irc", scope: roomDirectoryId, swiss: ircSwiss },
					],
					archivePeer: null,
				},
			}),
		);
		const peer = startRoomsSessionPeer(directory, peerPort, checkpointPath);
		try {
			const link = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "unnamed Rooms session peer");
			const parsed = parseSturdyRef(link, "v1_0");
			const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
			try {
				const client = new RoomsSessionClient(
					session,
					await session.enliven(link),
				);
				const snapshot = await client.snapshot();
				assert(
					snapshot.connectedDirectories.includes(roomDirectoryId),
					"the unnamed directory did not connect",
				);
				assert(
					!snapshot.issues.some((issue) => issue.subject.startsWith("capability:")),
					"the unnamed directory did not redeem its scoped operator capability",
				);
				await client.operatorSnapshot(roomDirectoryId);
				const listeners = await client.operationsSnapshot(roomDirectoryId, "listeners");
				assert(
					listeners.capability === "listeners" && listeners.rows.length > 0,
					"the durable session did not expose its listeners capability",
				);
				await client.operationsSnapshot(roomDirectoryId, "diagnostics");
				await client.operationsSnapshot(roomDirectoryId, "irc");
				let malformedListenerRefused = false;
				try {
					await client.command("malformed-listener", snapshot.revision, "operations", [
						roomDirectoryId,
						"listeners",
						"down",
						"not-a-listener-id",
					]);
				} catch {
					malformedListenerRefused = true;
				}
				assert(malformedListenerRefused, "a malformed listener operation was admitted");
				assert(
					!(await client.snapshot()).pendingEffects.includes("malformed-listener"),
					"local listener validation polluted the external-effect ledger",
				);
				let malformedIrcRefused = false;
				try {
					await client.command("malformed-irc", snapshot.revision, "operations", [
						roomDirectoryId,
						"irc",
						"join",
						"{}",
					]);
				} catch {
					malformedIrcRefused = true;
				}
				assert(malformedIrcRefused, "malformed IRC settings were admitted");
				assert(
					!(await client.snapshot()).pendingEffects.includes("malformed-irc"),
					"local IRC validation polluted the external-effect ledger",
				);
				let malformedOperatorRefused = false;
				try {
					await client.operator(
						"malformed-operator",
						snapshot.revision,
						roomDirectoryId,
						"notAnOperatorAction",
					);
				} catch {
					malformedOperatorRefused = true;
				}
				assert(malformedOperatorRefused, "a malformed operator action was admitted");
				assert(
					!(await client.snapshot()).pendingEffects.includes("malformed-operator"),
					"local operator validation polluted the external-effect ledger",
				);
				await client.command("listener-up", snapshot.revision, "operations", [
					roomDirectoryId,
					"listeners",
					"up",
					"noise-tcp",
					"{}",
				]);
				const broughtUp = await client.operationsSnapshot(roomDirectoryId, "listeners");
				assert(broughtUp.capability === "listeners", "the session answered the wrong operations snapshot");
				const noise = broughtUp.rows.find((row) => row.transport === "noise-tcp");
				assert(noise?.id != null, "the durable listener operation did not bring noise-tcp up");
				await client.command("listener-down", snapshot.revision, "operations", [
					roomDirectoryId,
					"listeners",
					"down",
					String(noise.id),
				]);
				const operationsChanged = Promise.withResolvers<string>();
				await client.watch(() => {}, () => {}, (scope) => operationsChanged.resolve(scope));
				assert(
					await client.operator(
						"clear-operator-trouble",
						snapshot.revision,
						roomDirectoryId,
						"clearTrouble",
					) ===
						snapshot.revision,
					"the operator invalidation changed the checkpoint revision",
				);
				assert(
					await within(operationsChanged.promise, "the shared operator invalidation") === roomDirectoryId,
					"the operator mutation did not invalidate every attached admin view",
				);
				const observed = await client.facet("observe");
				try {
					const publicSnapshot = await observed.session.snapshot();
					assert(
						publicSnapshot.checkpoint.capabilities.operations.length === 0,
						"an observe facet received the saved operator bearer",
					);
					let inspected = true;
					try {
						await observed.session.operatorSnapshot(roomDirectoryId);
					} catch {
						inspected = false;
					}
					assert(!inspected, "an observe facet reached operator inventory through the session owner");
					let inspectedListeners = true;
					try {
						await observed.session.operationsSnapshot(roomDirectoryId, "listeners");
					} catch {
						inspectedListeners = false;
					}
					assert(
						!inspectedListeners,
						"an observe facet reached listener inventory through the session owner",
					);
					let sentFiles = true;
					try {
						await observed.session.sendFiles("observe-files", publicSnapshot.revision, "missing", "", []);
					} catch {
						sentFiles = false;
					}
					assert(!sentFiles, "an observe facet reached the file-send effect");
					let refiled = true;
					try {
						await observed.session.refileLine(
							"observe-refile",
							publicSnapshot.revision,
							"missing",
							1,
							"",
							[],
							[],
						);
					} catch {
						refiled = false;
					}
					assert(!refiled, "an observe facet reached the file-refile effect");
				} finally {
					await observed.revoke();
				}
				const beforeReplacement = await client.snapshot();
				await client.replaceOperationsCapabilities(
					"replace-with-refused-capability",
					beforeReplacement.revision,
					[{ capability: "operator", scope: roomDirectoryId, swiss: "not-a-published-swiss-number" }],
				);
				const refusedCapability = await client.snapshot();
				assert(
					refusedCapability.issues.some((issue) =>
						issue.subject === `capability:operator\0${roomDirectoryId}` &&
						issue.reason ===
							"The directory does not recognize that swiss number. Use the value it currently prints as ROOMS-OPERATOR."
					),
					"capability replacement answered before runtime reconciliation exposed its actionable refusal",
				);
			} finally {
				await session.close();
			}
		} finally {
			await stopOwned(peer);
		}
	} finally {
		await stopServer(roomServer);
		await Deno.remove(directory, { recursive: true });
		await Deno.remove(roomDirectory, { recursive: true });
	}
});
