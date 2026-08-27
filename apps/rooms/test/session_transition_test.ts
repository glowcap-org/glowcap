import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { IO } from "@pancake/abi";
import { PancakeError } from "@pancake/runtime";
import type { RoomsSessionSnapshot } from "../lib/rooms_session.ts";
import {
	attachRoomsController,
	type RoomsControllerTransition,
	type VerifiedRoomsSession,
} from "../web/ui/session/controller_transition.ts";
import { assertEquals } from "./assert.ts";
import { roomsSessionSnapshot } from "./support/session_snapshot.ts";

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
