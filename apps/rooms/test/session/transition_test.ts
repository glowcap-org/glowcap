import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import { IO } from "@pancake/abi";
import { PancakeError } from "@pancake/runtime";
import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import {
	attachRoomsController,
	type RoomsControllerTransition,
	type VerifiedRoomsSession,
} from "../../web/ui/session/controller_transition.ts";
import { assertEquals } from "../assert.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";

function snapshot(
	workspaceAdoption: RoomsSessionSnapshot["workspaceAdoption"],
	checkpoint = emptyRoomsSessionState(),
): RoomsSessionSnapshot {
	return roomsSessionSnapshot({
		revision: workspaceAdoption === "available" ? 0 : 1,
		workspaceAdoption,
		checkpoint,
	});
}

Deno.test("attaching retires its verified connection before reload", async () => {
	const order: string[] = [];
	const controller = {
		current: snapshot("closed"),
		adoptWorkspace: () => Promise.reject(new Error("closed session unexpectedly requested adoption")),
		close: () => {
			order.push("close");
			return Promise.resolve();
		},
	} satisfies VerifiedRoomsSession;
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "local" }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => {
			order.push("connect");
			return Promise.resolve(controller);
		},
		verifyOverAttached: () => null,
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	const attaching = attachRoomsController("ocapn://session.example/s/admin", transition).then((why) => {
		order.push("settled");
		return why;
	});
	assertEquals(await attaching, "");
	assertEquals(order, ["connect", "select", "close", "settled"]);
});

Deno.test("a new shared session adopts local state before selection", async () => {
	const order: string[] = [];
	const local = { ...emptyRoomsSessionState(), standing: "local workspace" };
	const controller: VerifiedRoomsSession = {
		current: snapshot("available"),
		adoptWorkspace: (checkpoint) => {
			order.push(`adopt:${checkpoint.standing}`);
			return Promise.resolve(snapshot("closed", checkpoint));
		},
		close: () => {
			order.push("close");
			return Promise.resolve();
		},
	};
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "local" }),
		localCheckpoint: () => local,
		connect: () => {
			order.push("connect");
			return Promise.resolve(controller);
		},
		verifyOverAttached: () => null,
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	assertEquals(await attachRoomsController(" ocapn://session.example/s/admin ", transition), "");
	assertEquals(order, ["connect", "adopt:local workspace", "select", "close"]);
});

Deno.test("an unreachable shared session produces an actionable attachment refusal", async () => {
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "local" }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => Promise.reject(new PancakeError(IO, "dial failed: NetworkUnreachable")),
		verifyOverAttached: () => null,
		select: () => true,
		reportCleanupFailure: () => {},
	};
	assertEquals(
		await attachRoomsController("ocapn://session.example/s/admin", transition),
		"The shared session peer could not be reached. Make sure it is running and retry the " +
			"capability it currently announces. An iroh session needs either a reachable advertised address " +
			"or working iroh discovery and relay access.",
	);
});

Deno.test("a missing WebRTC signaling inbox is not reported as a truncated paste", async () => {
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "local" }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () =>
			Promise.reject(
				new Error("pancake error -12: peer-offline: no signaling inbox for that designator"),
			),
		verifyOverAttached: () => null,
		select: () => true,
		reportCleanupFailure: () => {},
	};
	const said = await attachRoomsController("ocapn://session.example/s/admin", transition);
	assertEquals(said.includes("hosting tab"), true);
	assertEquals(said.includes("Check that you pasted"), false);
	assertEquals(said.startsWith("pancake error"), false);
});

// Two capabilities for one peer, and one for another. Written with the app's
// own formatter so the shapes the transition compares cannot drift from the
// parser that reads them.
const attachedPeer = roomsLocator("127.0.0.1:7300");
const heldCapability = formatRoomsSturdyref(attachedPeer, "held-by-this-browser");
const spareCapability = formatRoomsSturdyref(attachedPeer, "issued-for-this-browser");
const elsewhereCapability = formatRoomsSturdyref(roomsLocator("127.0.0.1:7301"), "another-session");

Deno.test("a second capability for the attached peer is taken without opening a session", async () => {
	const order: string[] = [];
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "attached", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => {
			order.push("connect");
			return Promise.reject(new Error("a Host keeps one session per partner"));
		},
		verifyOverAttached: (sturdyref) => {
			order.push(`ask:${sturdyref}`);
			return Promise.resolve();
		},
		select: (controller) => {
			order.push(controller.kind === "attached" ? `select:${controller.sturdyref}` : "select:other");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	assertEquals(await attachRoomsController(` ${spareCapability} `, transition), "");
	assertEquals(order, [`ask:${spareCapability}`, `select:${spareCapability}`]);
});

Deno.test("a capability for another peer is still verified before it is taken", async () => {
	const order: string[] = [];
	const controller = {
		current: snapshot("closed"),
		adoptWorkspace: () => Promise.reject(new Error("closed session unexpectedly requested adoption")),
		close: () => {
			order.push("close");
			return Promise.resolve();
		},
	} satisfies VerifiedRoomsSession;
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "attached", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => {
			order.push("connect");
			return Promise.resolve(controller);
		},
		verifyOverAttached: () => null,
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	assertEquals(await attachRoomsController(elsewhereCapability, transition), "");
	assertEquals(order, ["connect", "select", "close"]);
});

Deno.test("a browser that refuses to save the swapped capability says so", async () => {
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "attached", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => Promise.reject(new Error("a Host keeps one session per partner")),
		verifyOverAttached: () => Promise.resolve(),
		select: () => false,
		reportCleanupFailure: () => {},
	};
	assertEquals(
		await attachRoomsController(spareCapability, transition),
		"This browser refused to save the shared session capability.",
	);
});

Deno.test("a second capability the session will not answer for is refused, not committed", async () => {
	const order: string[] = [];
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "attached", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => {
			order.push("connect");
			return Promise.reject(new Error("a Host keeps one session per partner"));
		},
		verifyOverAttached: () => {
			order.push("ask");
			return Promise.reject(new Error("the shared session did not answer for that capability"));
		},
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	assertEquals(
		await attachRoomsController(spareCapability, transition),
		"the shared session did not answer for that capability",
	);
	assertEquals(order, ["ask"]);
});

Deno.test("a second capability opens its own session when this browser holds none", async () => {
	const order: string[] = [];
	const controller = {
		current: snapshot("closed"),
		adoptWorkspace: () => Promise.reject(new Error("closed session unexpectedly requested adoption")),
		close: () => {
			order.push("close");
			return Promise.resolve();
		},
	} satisfies VerifiedRoomsSession;
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "attached", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => {
			order.push("connect");
			return Promise.resolve(controller);
		},
		// A browser between connections has nothing to ask, and the peer is
		// free, so the ordinary path reaches it.
		verifyOverAttached: () => null,
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => order.push("cleanup failure"),
	};
	assertEquals(await attachRoomsController(spareCapability, transition), "");
	assertEquals(order, ["connect", "select", "close"]);
});

Deno.test("hosting the session is already that peer", async () => {
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "hosted", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => Promise.reject(new Error("hosted unexpectedly dialed itself")),
		verifyOverAttached: () => Promise.reject(new Error("hosted unexpectedly asked a sibling")),
		select: () => {
			throw new Error("hosted unexpectedly changed controller");
		},
		reportCleanupFailure: () => {},
	};
	assertEquals(await attachRoomsController(heldCapability, transition), "");
});

Deno.test("a sibling grant for a hosted session does not stop hosting", async () => {
	const order: string[] = [];
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "hosted", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => Promise.reject(new Error("hosted unexpectedly dialed itself")),
		verifyOverAttached: (sturdyref) => {
			order.push(`ask:${sturdyref}`);
			return Promise.resolve();
		},
		select: (controller) => {
			order.push(`select:${controller.kind}`);
			return true;
		},
		reportCleanupFailure: () => {},
	};
	assertEquals(await attachRoomsController(spareCapability, transition), "");
	assertEquals(order, [`ask:${spareCapability}`]);
});

Deno.test("a sibling grant a hosted session will not answer for is refused, not committed", async () => {
	const order: string[] = [];
	const transition: RoomsControllerTransition = {
		current: () => ({ kind: "hosted", sturdyref: heldCapability }),
		localCheckpoint: emptyRoomsSessionState,
		connect: () => Promise.reject(new Error("hosted unexpectedly dialed itself")),
		verifyOverAttached: () => {
			order.push("ask");
			return Promise.reject(new Error("that capability is not published by this session"));
		},
		select: () => {
			order.push("select");
			return true;
		},
		reportCleanupFailure: () => {},
	};
	assertEquals(
		await attachRoomsController(spareCapability, transition),
		"that capability is not published by this session",
	);
	assertEquals(order, ["ask"]);
});
