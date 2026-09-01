// Connect on a shared session is the dial, not the workspace record.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

import { assertEquals } from "../assert.ts";
import {
	directoryReachIsStanding,
	directoryReachOutcome,
	waitForDirectoryReach,
} from "../../web/ui/session/attached_directory_reach.ts";
import { directoryLivePhase } from "../../web/ui/types.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";
import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";

Deno.test("a failed Connect forgets only an address that has never answered", () => {
	assertEquals(directoryReachIsStanding(undefined), false);
	assertEquals(directoryReachIsStanding({ home: false, reached: false }), false);
	assertEquals(directoryReachIsStanding({ home: false }), false);
	assertEquals(directoryReachIsStanding({ home: false, reached: true }), true);
	assertEquals(directoryReachIsStanding({ home: true, reached: false }), true);
});

Deno.test("a directory that has not answered is connecting; one that has, then dropped, is reconnecting", () => {
	assertEquals(directoryLivePhase(false, false, undefined), { session: "connecting", statusText: "" });
	assertEquals(directoryLivePhase(true, false, undefined), { session: "reconnecting", statusText: "" });
	assertEquals(directoryLivePhase(false, true, undefined), { session: "connected", statusText: "" });
	assertEquals(directoryLivePhase(true, true, undefined), { session: "connected", statusText: "" });
	assertEquals(directoryLivePhase(true, false, "directory refused the connection"), {
		session: "disconnected",
		statusText: "directory refused the connection",
	});
	assertEquals(directoryLivePhase(false, true, "the shared session ended"), {
		session: "disconnected",
		statusText: "the shared session ended",
	});
});

Deno.test("a directory is reached only once it is connected, and refused by its own issue", () => {
	assertEquals(directoryReachOutcome(null, "away"), undefined);
	assertEquals(directoryReachOutcome(roomsSessionSnapshot(), "away"), undefined);
	assertEquals(
		directoryReachOutcome(roomsSessionSnapshot({ connectedDirectories: ["away"] }), "away"),
		"",
	);
	assertEquals(
		directoryReachOutcome(
			roomsSessionSnapshot({
				issues: [{ subject: "directory:away", reason: "that address did not answer" }],
			}),
			"away",
		),
		"that address did not answer",
	);
	assertEquals(
		directoryReachOutcome(
			roomsSessionSnapshot({ issues: [{ subject: "session", reason: "the shared session ended" }] }),
			"away",
		),
		"the shared session ended",
	);
	assertEquals(
		directoryReachOutcome(
			roomsSessionSnapshot({
				issues: [{
					subject: "session-access",
					reason: "This session capability was revoked. Detach it or attach with another capability.",
				}],
			}),
			"away",
		),
		"This session capability was revoked. Detach it or attach with another capability.",
	);
});

Deno.test("waiting for a directory settles on the first reach or refusal, and stop is not a refusal", async () => {
	let snapshot = roomsSessionSnapshot();
	const listeners = new Set<(next: RoomsSessionSnapshot) => void>();
	const source = {
		get current() {
			return snapshot;
		},
		onSnapshot(listener: (next: RoomsSessionSnapshot) => void) {
			listeners.add(listener);
			return () => listeners.delete(listener);
		},
	};
	const push = (next: RoomsSessionSnapshot) => {
		snapshot = next;
		for (const listener of listeners) listener(next);
	};

	const reached = waitForDirectoryReach(source, "away");
	push(roomsSessionSnapshot({ connectedDirectories: ["away"] }));
	assertEquals(await reached, "");

	snapshot = roomsSessionSnapshot();
	const refused = waitForDirectoryReach(source, "away");
	push(roomsSessionSnapshot({
		issues: [{ subject: "directory:away", reason: "that address did not answer" }],
	}));
	assertEquals(await refused, "that address did not answer");

	snapshot = roomsSessionSnapshot({ connectedDirectories: ["away"] });
	assertEquals(await waitForDirectoryReach(source, "away"), "");

	snapshot = roomsSessionSnapshot();
	const stop = new AbortController();
	const stopped = waitForDirectoryReach(source, "other", stop.signal);
	stop.abort();
	assertEquals(await stopped, "");
});

Deno.test("two attached directories keep distinct connection words", async () => {
	const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
	const store = await import("../../web/ui/store.ts");
	const { RoomsPage } = await import("../../web/ui/page.ts");
	const { dirId } = await import("../../web/ui/types.ts");
	const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
	const { adminSessionView } = await import("../support/session_snapshot.ts");
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [
			{ id: "home", locator: "127.0.0.1:1", home: true, reached: true, nick: "ada", standing: null },
			{ id: "away", locator: "127.0.0.1:2", home: false, reached: false, nick: "ada", standing: null },
		],
	};
	const apply = (connected: readonly string[], issues: { subject: string; reason: string }[] = []) =>
		projection.apply({
			revision: 1,
			...adminSessionView(),
			checkpoint,
			pendingEffects: [],
			pendingEffectDetails: [],
			issues,
			connectedDirectories: [...connected],
			memberLocator: null,
			roomViews: [],
		});
	const home = dirId("home");
	const away = dirId("away");
	apply(["home"]);
	assertEquals(page.projection.get().dirs.get(home)?.session, "connected");
	assertEquals(page.projection.get().dirs.get(away)?.session, "connecting");
	apply([]);
	assertEquals(page.projection.get().dirs.get(home)?.session, "reconnecting");
	assertEquals(page.projection.get().dirs.get(away)?.session, "connecting");
	apply([], [{ subject: "directory:away", reason: "that address did not answer" }]);
	assertEquals(page.projection.get().dirs.get(home)?.session, "reconnecting");
	assertEquals(page.projection.get().dirs.get(away)?.session, "disconnected");
	apply(["home"], [{ subject: "session", reason: "the shared session ended" }]);
	assertEquals(page.projection.get().dirs.get(home)?.session, "disconnected");
	assertEquals(page.projection.get().dirs.get(away)?.session, "disconnected");
	store.forgetDir(page.projection, home);
	store.forgetDir(page.projection, away);
});
