import { emptyRoomsSessionState, redactRoomsSessionCapabilities, type RoomsSessionState } from "../lib/rooms_state.ts";
import { DurableRoomsSessionState } from "../session/state.ts";
import {
	applyRoomsSessionCommand,
	applyRoomsSessionResult,
	prepareRoomOffer,
	prepareRoomsSessionResult,
	resumeRoomsSessionResult,
} from "../session/commands.ts";
import {
	assertSessionCommandEnvelope,
	MAX_SESSION_COMMAND_ARGUMENTS,
	MAX_SESSION_COMMAND_BYTES,
} from "../session/behavior.ts";
import { loopbackTcpDesignator, roomsLocator } from "../lib/locator.ts";
import { roomsPeerAuthority } from "../lib/routes.ts";
import { validateOperationId } from "../session/effects.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

function syncRefused(work: () => unknown): boolean {
	try {
		work();
		return false;
	} catch {
		return true;
	}
}

function joinRoomState(
	state: RoomsSessionState,
	conversation: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
): RoomsSessionState {
	const directory = state.directories.find((entry) => entry.id === conversation.directory);
	if (directory == null) throw new Error("the room fixture names no directory");
	return applyRoomsSessionCommand(state, "joinRoom", [JSON.stringify({
		locator: directory.locator,
		nick: directory.nick,
		conversation,
	})]);
}

Deno.test("a durable Rooms session commits one revision and deduplicates retries", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		assertEquals(state.snapshot().revision, 0);
		const checkpoint = { ...emptyRoomsSessionState(), standing: "working elsewhere" };
		let observed = 0;
		state.onChange((revision) => observed = revision);
		assertEquals(await state.replace("operation-1", 0, checkpoint), 1);
		assertEquals(observed, 1);
		assertEquals(await state.replace("operation-1", 0, checkpoint), 1);
		assertEquals(observed, 1);
		assertEquals(
			await refused(() => state.replace("operation-1", 1, { ...checkpoint, standing: "different" })),
			true,
		);
		assertEquals(await refused(() => state.replace("operation-2", 0, checkpoint)), true);

		const restored = await DurableRoomsSessionState.open(directory);
		assertEquals(restored.snapshot().revision, 1);
		assertEquals(restored.snapshot().checkpoint.standing, "working elsewhere");
		assertEquals(await restored.replace("operation-1", 0, checkpoint), 1);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("effect status and checkpoint reconciliation have separate observers", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-observers-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		let statusChanges = 0;
		let checkpointChanges = 0;
		let impact = "";
		state.onChange(() => statusChanges += 1);
		state.onCheckpointChange((_revision, _checkpoint, changed) => {
			checkpointChanges += 1;
			impact = changed;
		});
		await state.prepareEffect("external", 0, '["say","room","hello"]');
		assertEquals(statusChanges, 1);
		assertEquals(checkpointChanges, 0);
		await state.resolveEffect("external", "abandoned");
		assertEquals(statusChanges, 2);
		assertEquals(checkpointChanges, 0);
		await state.mutate({
			operationId: "draft",
			baseRevision: 0,
			material: "draft",
			impact: "presentation",
			change: (checkpoint) => checkpoint,
		});
		assertEquals(statusChanges, 3);
		assertEquals(checkpointChanges, 1);
		assertEquals(impact, "presentation");
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("effect preflight refuses before persistence but never overrides a committed retry", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-effect-preflight-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const material = '["say","direct","hello"]';
		assertEquals(
			await refused(() =>
				state.prepareEffect("not-connected", 0, material, () => {
					throw new Error("the direct conversation is not connected");
				})
			),
			true,
		);
		assertEquals(state.pendingEffectIds(), []);
		assertEquals((await state.prepareEffect("committed-send", 0, material)).kind, "prepared");
		assertEquals(await state.commitEffect("committed-send", material), 0);
		assertEquals(
			await state.prepareEffect("committed-send", 0, material, () => {
				throw new Error("a committed retry must not rerun preflight");
			}),
			{ kind: "committed", revision: 0 },
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("effect inspection leaves the state serializer free before realized admission", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-effect-realization-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const material = '["say","direct","hello"]';
		const inspection = await state.inspectEffect("await-realization", 0, material);
		if (inspection.kind !== "new") throw new Error("a fresh effect inspection was not new");
		assertEquals(state.pendingEffectIds(), []);
		assertEquals(
			await refused(() => state.prepareInspectedEffect(inspection, '["say","direct","changed"]', () => {})),
			true,
		);
		assertEquals(state.pendingEffectIds(), []);
		assertEquals(
			await state.replace("parallel-workspace-change", 0, {
				...emptyRoomsSessionState(),
				standing: "changed while the network was opening",
			}),
			1,
		);
		let checked = false;
		assertEquals(
			await state.prepareInspectedEffect(inspection, material, () => {
				checked = true;
			}).then((result) => result.kind),
			"prepared",
		);
		assertEquals(checked, true);
		assertEquals(state.pendingEffectIds(), ["await-realization"]);
		assertEquals(await state.commitEffect("await-realization", material), 1);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("an observer failure cannot turn a durable checkpoint commit into a refusal", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-observer-failure-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		state.onCheckpointChange(() => {
			throw new Error("observer failed");
		});
		assertEquals(await state.replace("committed", 0, emptyRoomsSessionState()), 1);
		assertEquals(state.snapshot().revision, 1);
		assertEquals((await DurableRoomsSessionState.open(directory)).snapshot().revision, 1);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("the durable checkpoint owner refuses invalid in-memory state before writing", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-invalid-write-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const invalid = { ...emptyRoomsSessionState(), unexpectedRuntimeState: true } as unknown as ReturnType<
			typeof emptyRoomsSessionState
		>;
		assertEquals(await refused(() => state.replace("invalid", 0, invalid)), true);
		assertEquals(state.snapshot().revision, 0);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a checkpoint snapshot exposes no unrevisioned mutation path", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-frozen-snapshot-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const snapshot = state.snapshot();
		let refused = false;
		try {
			(snapshot.checkpoint as { standing: string }).standing = "mutated";
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		assertEquals(state.snapshot().checkpoint.standing, "");
		assertEquals(state.snapshot().revision, 0);
		const seed = state.identitySeed;
		seed[0] ^= 0xff;
		assertEquals(state.identitySeed[0] === seed[0], false);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("corrupt durable Rooms session state refuses startup", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-corrupt-" });
	try {
		await Deno.writeTextFile(`${directory}/session.json`, '{"version":1');
		assertEquals(await refused(() => DurableRoomsSessionState.open(directory)), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a checkpoint over the aggregate byte ceiling is refused before disk commit", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-size-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const checkpoint = {
			...emptyRoomsSessionState(),
			standing: "x".repeat(64 * 1024),
			ignored: Array.from({ length: 512 }, (_, index) => `ignored-${index}-${"x".repeat(1500)}`),
		};
		const before = await Deno.readTextFile(`${directory}/session.json`);
		assertEquals(await refused(() => state.replace("too-large", 0, checkpoint)), true);
		assertEquals(await Deno.readTextFile(`${directory}/session.json`), before);
		assertEquals((await DurableRoomsSessionState.open(directory)).snapshot().revision, 0);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("an existing checkpoint refuses a missing external-effect ledger", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-missing-effects-" });
	try {
		await DurableRoomsSessionState.open(directory);
		await Deno.remove(`${directory}/effects.json`);
		assertEquals(await refused(() => DurableRoomsSessionState.open(directory)), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a prepared external effect survives restart and never retries implicitly", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-pending-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const checkpointFile = await Deno.readTextFile(`${directory}/session.json`);
		assertEquals((await state.prepareEffect("send-1", 0, '["say","room","hello"]')).kind, "prepared");
		assertEquals(state.pendingEffectIds(), ["send-1"]);
		assertEquals(await Deno.readTextFile(`${directory}/session.json`), checkpointFile);
		const restored = await DurableRoomsSessionState.open(directory);
		assertEquals(restored.snapshot().revision, 0);
		assertEquals(restored.pendingEffectDetails()[0]?.intent, "Send a message");
		assertEquals(
			await refused(() => restored.prepareEffect("send-1", 0, '["say","room","hello"]')),
			true,
		);
		assertEquals(
			await refused(() => restored.prepareEffect("send-1", 0, '["say","room","different"]')),
			true,
		);
		await restored.resolveEffect("send-1", "abandoned");
		assertEquals(restored.pendingEffectIds(), []);
		assertEquals(await Deno.readTextFile(`${directory}/session.json`), checkpointFile);
		assertEquals(
			await refused(() => restored.prepareEffect("send-1", 0, '["say","room","hello"]')),
			true,
		);
		assertEquals((await restored.prepareEffect("send-2", 0, '["say","room","second"]')).kind, "prepared");
		assertEquals(await restored.commitEffect("send-2", '["say","room","second"]'), 0);
		assertEquals((await restored.prepareEffect("send-2", 0, '["say","room","second"]')).kind, "committed");
		assertEquals(await Deno.readTextFile(`${directory}/session.json`), checkpointFile);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("interaction commands express workspace acts without checkpoint replacement", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-id",
		directory: directory.id,
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	const direct = {
		kind: "direct" as const,
		id: "direct-id",
		directory: directory.id,
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "hello",
	};
	let state = emptyRoomsSessionState();
	state = applyRoomsSessionCommand(state, "joinDirectory", [JSON.stringify(directory)]);
	state = joinRoomState(state, room);
	state = applyRoomsSessionCommand(state, "startDirect", [JSON.stringify(direct)]);
	state = applyRoomsSessionCommand(state, "select", [direct.id]);
	state = applyRoomsSessionCommand(state, "setDirectoryStanding", [directory.id, "away"]);
	state = applyRoomsSessionCommand(state, "setRoomStanding", [room.id, "reading"]);
	state = applyRoomsSessionCommand(state, "setIgnoredNames", [JSON.stringify(["noise"])]);
	state = applyRoomsSessionCommand(state, "chooseHistoryRetention", ["false"]);
	state = applyRoomsSessionCommand(state, "chooseConnection", ["relay", "ws://rooms.test/viz"]);
	state = applyRoomsSessionCommand(state, "replaceOperationsCapabilities", [JSON.stringify([{
		capability: "operator",
		scope: directory.id,
		swiss: "operator-swiss",
	}])]);
	state = applyRoomsSessionCommand(state, "selectArchive", ["ocapn://archive.iroh/s/archive"]);
	assertEquals(state.directories[0].standing, "away");
	assertEquals(state.conversations[0].kind === "room" ? state.conversations[0].standing : null, "reading");
	assertEquals(state.active, direct.id);
	assertEquals(state.ignored, ["noise"]);
	assertEquals(state.keepHistory, false);
	assertEquals(state.join, { room: "general", locator: "", nick: "ada" });
	assertEquals(state.dmMode, "relay");
	assertEquals(state.capabilities.operations[0].swiss, "operator-swiss");
	state = applyRoomsSessionCommand(state, "closeDirect", [direct.id]);
	assertEquals(state.conversations.find((entry) => entry.id === direct.id)?.kind === "direct", true);
	state = applyRoomsSessionCommand(state, "leaveDirectory", [directory.id]);
	assertEquals(state.directories.length, 0);
	assertEquals(state.conversations.length, 0);
	assertEquals(state.capabilities.operations.length, 0);
	assertEquals(state.active, null);

	let refusedDuplicate = false;
	try {
		let duplicate = applyRoomsSessionCommand(emptyRoomsSessionState(), "joinDirectory", [
			JSON.stringify(directory),
		]);
		duplicate = applyRoomsSessionCommand(duplicate, "joinDirectory", [JSON.stringify(directory)]);
	} catch {
		refusedDuplicate = true;
	}
	assertEquals(refusedDuplicate, true);
});

Deno.test("releasing one directory nickname preserves its workspace intent", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-id",
		directory: directory.id,
		name: "general",
		held: false,
		standing: null,
		draft: "unfinished",
	};
	let state = applyRoomsSessionCommand(emptyRoomsSessionState(), "joinDirectory", [JSON.stringify(directory)]);
	state = joinRoomState(state, room);
	state = applyRoomsSessionCommand(state, "replaceOperationsCapabilities", [JSON.stringify([{
		capability: "operator",
		scope: directory.id,
		swiss: "operator-swiss",
	}])]);
	state = applyRoomsSessionCommand(state, "setDirectoryNick", [directory.id, ""]);
	assertEquals(state.directories[0].nick, "");
	assertEquals(state.conversations, [room]);
	assertEquals(state.capabilities.operations.length, 1);
	state = applyRoomsSessionCommand(state, "setDirectoryNick", [directory.id, "ada"]);
	assertEquals(state.directories[0].nick, "ada");
	assertEquals(state.conversations, [room]);
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(state, "setDirectoryNick", [directory.id, "room"])),
		true,
	);
	assertEquals(state.directories[0].nick, "ada");
});

Deno.test("shared capability replacement removes dependent peering intent atomically", () => {
	const source = {
		id: "ocapn://source.id",
		locator: "ocapn://source.id",
		home: true,
		nick: "ada",
		standing: null,
	};
	const destination = { ...source, id: "ocapn://destination.id", locator: "ocapn://destination.id", home: false };
	const room = {
		kind: "room" as const,
		id: "source-room",
		directory: source.id,
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	let state = applyRoomsSessionCommand(emptyRoomsSessionState(), "joinDirectory", [JSON.stringify(source)]);
	state = applyRoomsSessionCommand(state, "joinDirectory", [JSON.stringify(destination)]);
	state = joinRoomState(state, room);
	state = applyRoomsSessionCommand(state, "replaceOperationsCapabilities", [JSON.stringify([{
		capability: "peering",
		scope: destination.id,
		swiss: "peering-swiss",
	}])]);
	state = applyRoomsSessionCommand(state, "publishPeeredRoom", [JSON.stringify({
		id: "publication",
		destination: destination.id,
		source: room.id,
		name: "annex",
	})]);
	state = applyRoomsSessionCommand(state, "replaceOperationsCapabilities", ["[]"]);
	assertEquals(state.capabilities.operations, []);
	assertEquals(state.peering, []);
});

Deno.test("leaving a peering source or destination removes its dependent intent atomically", () => {
	const source = {
		id: "ocapn://source.id",
		locator: "ocapn://source.id",
		home: true,
		nick: "ada",
		standing: null,
	};
	const destination = { ...source, id: "ocapn://destination.id", locator: "ocapn://destination.id", home: false };
	const room = {
		kind: "room" as const,
		id: "source-room",
		directory: source.id,
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	const withPublication = () => {
		let state = applyRoomsSessionCommand(emptyRoomsSessionState(), "joinDirectory", [JSON.stringify(source)]);
		state = applyRoomsSessionCommand(state, "joinDirectory", [JSON.stringify(destination)]);
		state = joinRoomState(state, room);
		state = applyRoomsSessionCommand(state, "replaceOperationsCapabilities", [JSON.stringify([{
			capability: "peering",
			scope: destination.id,
			swiss: "peering-swiss",
		}])]);
		return applyRoomsSessionCommand(state, "publishPeeredRoom", [JSON.stringify({
			id: "publication",
			destination: destination.id,
			source: room.id,
			name: "annex",
		})]);
	};
	const withoutSource = applyRoomsSessionCommand(withPublication(), "leaveConversation", [room.id]);
	assertEquals(withoutSource.peering, []);
	const withoutDestination = applyRoomsSessionCommand(withPublication(), "leaveDirectory", [destination.id]);
	assertEquals(withoutDestination.peering, []);
});

Deno.test("room links and moderator authorities apply to the exact conversation", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-1",
		directory: directory.id,
		name: "plans",
		held: true,
		standing: null,
		draft: "draft",
	};
	const initial = { ...emptyRoomsSessionState(), directories: [directory], conversations: [room] };
	const linkPlan = prepareRoomsSessionResult(initial, "ensureRoomLink", [room.id]);
	assertEquals(linkPlan.kind, "room-link");
	let linked = applyRoomsSessionResult(
		initial,
		linkPlan.kind,
		linkPlan.intent,
		JSON.stringify({ roomLink: `${directory.id}/s/room-link` }),
	);
	const suppliedModerator = `${directory.id}/s/supplied-room-moderator`;
	const moderatorPlan = prepareRoomsSessionResult(linked, "takeRoomModerator", [room.id, suppliedModerator]);
	assertEquals(moderatorPlan.kind, "room-steward");
	assertEquals(moderatorPlan.stewardLink, suppliedModerator);
	assertEquals(
		syncRefused(() =>
			applyRoomsSessionResult(
				linked,
				moderatorPlan.kind,
				moderatorPlan.intent,
				JSON.stringify({
					roomLink: `${directory.id}/s/room-link`,
					stewardLink: `${directory.id}/s/a-different-room-moderator`,
				}),
			)
		),
		true,
	);
	linked = applyRoomsSessionResult(
		linked,
		moderatorPlan.kind,
		moderatorPlan.intent,
		JSON.stringify({
			roomLink: `${directory.id}/s/room-link`,
			stewardLink: suppliedModerator,
		}),
	);
	const saved = linked.conversations[0];
	assertEquals(saved.kind === "room" ? saved.link : null, `${directory.id}/s/room-link`);
	assertEquals(saved.kind === "room" ? saved.steward : null, suppliedModerator);
	const resumed = resumeRoomsSessionResult(linked, moderatorPlan.kind, moderatorPlan.intent);
	assertEquals(resumed.kind, "room-steward");
});

Deno.test("offerRoom accepts only a linked room and its open same-directory direct", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-1",
		directory: directory.id,
		name: "plans",
		held: true,
		link: "ocapn://directory.iroh/s/room-link",
		standing: null,
		draft: "",
	};
	const direct = {
		kind: "direct" as const,
		id: "direct-1",
		directory: directory.id,
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	};
	const current = { ...emptyRoomsSessionState(), directories: [directory], conversations: [room, direct] };
	assertEquals(prepareRoomOffer(current, [room.id, direct.id]), {
		roomConversationId: room.id,
		directConversationId: direct.id,
		label: room.name,
		link: room.link,
	});
	assertEquals(syncRefused(() => prepareRoomOffer(current, [direct.id, room.id])), true);
	assertEquals(
		syncRefused(() =>
			prepareRoomOffer({ ...current, conversations: [{ ...room, link: undefined }, direct] }, [
				room.id,
				direct.id,
			])
		),
		true,
	);
});

Deno.test("IRC identity is durable session intent and redacts as authority", () => {
	const locator = loopbackTcpDesignator(1);
	const directory = {
		id: roomsPeerAuthority(roomsLocator(locator)),
		locator,
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-1",
		directory: directory.id,
		name: "general",
		held: true,
		standing: null,
		draft: "",
	};
	let current = {
		...emptyRoomsSessionState(),
		directories: [directory],
		conversations: [room],
	} as import("../lib/rooms_state.ts").RoomsSessionState;
	current = applyRoomsSessionCommand(current, "connectRoomIrc", [room.id, "ircAda", "account", "password"]);
	const identity = current.conversations[0];
	assertEquals(identity.kind === "room" && "irc" in identity ? identity.irc : null, {
		nick: "ircAda",
		account: "account",
		password: "password",
	});
	const redacted = redactRoomsSessionCapabilities(current).conversations[0];
	assertEquals(redacted.kind === "room" && "irc" in redacted ? redacted.irc : null, null);
	current = applyRoomsSessionCommand(current, "disconnectRoomIrc", [room.id]);
	const disconnected = current.conversations[0];
	assertEquals(disconnected.kind === "room" && Object.hasOwn(disconnected, "irc"), true);
	assertEquals(disconnected.kind === "room" ? disconnected.irc : undefined, null);
	const redactedRoomsOnly = redactRoomsSessionCapabilities(current).conversations[0];
	assertEquals(redactedRoomsOnly.kind === "room" ? redactedRoomsOnly.irc : undefined, null);
});

Deno.test("session command envelopes refuse count and encoded-byte overflow before materialization", () => {
	const tooMany = [
		"operation",
		0n,
		"command",
		...Array.from({ length: MAX_SESSION_COMMAND_ARGUMENTS + 1 }, () => "x"),
	];
	assertEquals(syncRefused(() => assertSessionCommandEnvelope(tooMany)), true);
	const tooLarge = ["operation", 0n, "command", "x".repeat(MAX_SESSION_COMMAND_BYTES)];
	assertEquals(syncRefused(() => assertSessionCommandEnvelope(tooLarge)), true);
	assertSessionCommandEnvelope(["operation", 0n, "command", "bounded"]);
});

Deno.test("the effect ledger owns the bounded operation identity grammar", () => {
	assertEquals(validateOperationId("operation"), "operation");
	assertEquals(syncRefused(() => validateOperationId("")), true);
	assertEquals(syncRefused(() => validateOperationId("x".repeat(129))), true);
	assertEquals(syncRefused(() => validateOperationId(42)), true);
});
