import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { DurableRoomsSessionBehavior } from "../../session/behavior.ts";
import { applyRoomsSessionCommand } from "../../session/commands.ts";
import { assertEquals } from "../assert.ts";
import type { RoomsSessionGrantAuthority } from "../../session/grants.ts";
import { fixtureSturdyref } from "../support/workspace.ts";
import { openSessionState } from "../support/session_disk.ts";
import { DurableHandedRooms } from "../../session/handed_rooms.ts";
import { Ref, type Session } from "@glowcap/runtime";

function syncRefused(work: () => unknown): boolean {
	try {
		work();
		return false;
	} catch {
		return true;
	}
}

Deno.test("a durable session holds a handed room only until accept, decline, or owner close", async () => {
	const room = Object.create(Ref.prototype) as Ref;
	const link = fixtureSturdyref("ocapn://directory.example", "handed-room");
	let onClose = () => {};
	let released = 0;
	let changes = 0;
	const owner = {
		onClose: (callback: () => void) => {
			onClose = callback;
			return () => {};
		},
		send: () => Promise.resolve(link),
		release: (releasedRoom: Ref) => {
			if (releasedRoom !== room) throw new Error("the handed-room owner released another capability");
			released += 1;
		},
	} as unknown as Session;
	const handed = new DurableHandedRooms(() => changes += 1);
	handed.receive("directory", owner, "plans", room, "bo");
	const invitation = handed.list()[0];
	assertEquals(invitation?.label, "plans");
	assertEquals(
		await handed.accept(invitation.id, (_view, receivedLink) => {
			assertEquals(receivedLink, link);
			return Promise.resolve(7);
		}),
		7,
	);
	assertEquals(released, 1);
	assertEquals(handed.list(), []);

	handed.receive("directory", owner, "temporary", room, "bo");
	onClose();
	assertEquals(handed.list(), []);
	assertEquals(released, 1);
	assertEquals(changes, 4);
});

Deno.test("room-link invitations are accepted or dismissed atomically and exactly once", () => {
	const directory = {
		id: "ocapn://directory.id",
		locator: "ocapn://directory.id",
		home: true,
		nick: "ada",
		standing: null,
	};
	const invitation = {
		kind: "room-link" as const,
		id: "invite-1",
		directory: directory.id,
		locator: directory.locator,
		nick: directory.nick,
		label: "plans",
		from: "bo",
		link: fixtureSturdyref("ocapn://directory.iroh", "room-link"),
	};
	const initial = { ...emptyRoomsSessionState(), directories: [directory], invitations: [invitation] };
	const accepted = applyRoomsSessionCommand(initial, "acceptInvitation", [invitation.id, "room-1"]);
	assertEquals(accepted.invitations, []);
	assertEquals(accepted.active, "room-1");
	assertEquals(accepted.conversations[0], {
		kind: "room",
		id: "room-1",
		directory: directory.id,
		name: "plans",
		held: true,
		link: invitation.link,
		standing: null,
		draft: "",
	});
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(accepted, "acceptInvitation", [invitation.id, "room-2"])),
		true,
	);
	assertEquals(
		applyRoomsSessionCommand(initial, "dismissInvitation", [invitation.id]).invitations,
		[],
	);
	assertEquals(applyRoomsSessionCommand(initial, "leaveDirectory", [directory.id]).invitations, []);
});

Deno.test("invitation admission takes its revision at serialized execution time", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-invitation-queue-" });
	try {
		const state = await openSessionState(directory);
		await state.replace("directory", 0, {
			...emptyRoomsSessionState(),
			directories: [{
				id: "ocapn://directory.example",
				locator: "ocapn://directory.example",
				home: true,
				nick: "ada",
				standing: null,
			}],
		});
		let receive!: (
			directory: string,
			label: string,
			link: string,
			from: string,
			locator: string,
			nick: string,
		) => Promise<void> | void;
		const runtime = {
			onStatus: () => () => {},
			onOperationsInvalidated: () => () => {},
			onMessage: () => () => {},
			issues: () => [],
			connectedDirectories: () => [],
			memberLocator: () => null,
			roomViews: () => [],
			archiveShares: () => [],
			directoryViews: () => [],
			onInvitation: (callback: typeof receive) => {
				receive = callback;
				return () => {};
			},
		} as unknown as import("../../session/runtime.ts").DurableRoomsRuntime;
		const grants: RoomsSessionGrantAuthority = {
			restore: () => Promise.resolve(),
			list: () => [],
			issue: () => Promise.reject(new Error("invitation test does not issue session grants")),
			setPolicy: () => Promise.reject(new Error("invitation test does not administer session grants")),
			revoke: () => Promise.resolve(false),
			active: () => false,
			policy: () => null,
			onChange: () => () => {},
		};
		new DurableRoomsSessionBehavior(state, runtime, grants);
		const first = receive(
			"ocapn://directory.example",
			"first",
			fixtureSturdyref("ocapn://directory.example", "first"),
			"bo",
			"ocapn://directory.example",
			"ada",
		);
		const second = receive(
			"ocapn://directory.example",
			"second",
			fixtureSturdyref("ocapn://directory.example", "second"),
			"bo",
			"ocapn://directory.example",
			"ada",
		);
		await Promise.all([first, second]);
		assertEquals(state.snapshot().checkpoint.invitations.length, 2);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a cross-directory invitation carries its route through acceptance", () => {
	const invitation = {
		kind: "room-link" as const,
		id: "invite-cross-directory",
		directory: "ocapn://target.id",
		locator: "ocapn://target.id",
		nick: "ada",
		label: "shared plans",
		from: "bo",
		link: fixtureSturdyref("ocapn://target.id", "room-link"),
	};
	const initial = { ...emptyRoomsSessionState(), invitations: [invitation] };
	const accepted = applyRoomsSessionCommand(initial, "acceptInvitation", [invitation.id, "room-cross"]);
	assertEquals(accepted.directories, [{
		id: invitation.directory,
		locator: invitation.locator,
		home: false,
		nick: invitation.nick,
		standing: null,
	}]);
	assertEquals(accepted.invitations, []);
	assertEquals(accepted.active, "room-cross");
	assertEquals(accepted.conversations[0].directory, invitation.directory);
});

Deno.test("a pending cross-directory invitation survives durable session restart", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-cross-directory-invite-" });
	try {
		const invitation = {
			kind: "room-link" as const,
			id: "invite-restart",
			directory: "ocapn://target.id",
			locator: "ocapn://target.id",
			nick: "ada",
			label: "restartable room",
			from: "bo",
			link: fixtureSturdyref("ocapn://target.id", "room-link"),
		};
		const state = await openSessionState(directory);
		await state.replace("retain-invitation", 0, { ...emptyRoomsSessionState(), invitations: [invitation] });
		const restored = await openSessionState(directory);
		assertEquals(restored.snapshot().checkpoint.invitations, [invitation]);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("invitation acceptance refuses a bad route or nickname without mutating state", () => {
	const base = {
		...emptyRoomsSessionState(),
		invitations: [{
			kind: "room-link" as const,
			id: "invite-invalid",
			directory: "ocapn://target.id",
			locator: "not a locator",
			nick: "ada",
			label: "shared plans",
			from: "bo",
			link: fixtureSturdyref("ocapn://target.id", "room-link"),
		}],
	};
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(base, "acceptInvitation", ["invite-invalid", "room"])),
		true,
	);
	assertEquals(base.directories, []);
	assertEquals(base.invitations.length, 1);

	const refusedNick = {
		...base,
		invitations: [{ ...base.invitations[0], id: "invite-nick", locator: "ocapn://target.id", nick: "" }],
	};
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(refusedNick, "acceptInvitation", ["invite-nick", "room"])),
		true,
	);
});
