import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { DurableRoomsSessionState } from "../session/state.ts";
import { assertEquals } from "./assert.ts";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

Deno.test("a new session accepts one initial workspace and keeps that fact across restart", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-adoption-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		assertEquals(state.workspaceAdoption, "available");
		const adopted = { ...emptyRoomsSessionState(), standing: "adopted workspace" };
		assertEquals(await state.adoptWorkspace("adopt-workspace", 0, adopted), 1);
		assertEquals(state.workspaceAdoption, "closed");
		assertEquals(await state.adoptWorkspace("adopt-workspace", 0, adopted), 1);
		assertEquals(
			await refused(() => state.adoptWorkspace("replace-established", 1, emptyRoomsSessionState())),
			true,
		);
		const restored = await DurableRoomsSessionState.open(directory);
		assertEquals(restored.workspaceAdoption, "closed");
		assertEquals(restored.snapshot().checkpoint.standing, "adopted workspace");
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("an ordinary empty checkpoint closes initial workspace adoption", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-established-empty-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		assertEquals(await state.replace("establish-empty", 0, emptyRoomsSessionState()), 1);
		assertEquals(state.workspaceAdoption, "closed");
		assertEquals(
			await refused(() => state.adoptWorkspace("late-adoption", 1, emptyRoomsSessionState())),
			true,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("an older prerelease session envelope refuses without rewriting", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-old-envelope-" });
	try {
		await DurableRoomsSessionState.open(directory);
		const path = `${directory}/session.json`;
		const old = JSON.parse(await Deno.readTextFile(path));
		old.version = 2;
		delete old.workspaceAdoption;
		const encoded = JSON.stringify(old) + "\n";
		await Deno.writeTextFile(path, encoded);
		assertEquals(await refused(() => DurableRoomsSessionState.open(directory)), true);
		assertEquals(await Deno.readTextFile(path), encoded);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("session storage refuses workspace adoption after a checkpoint revision", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-adoption-conflict-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		await state.replace("checkpoint", 0, emptyRoomsSessionState());
		const path = `${directory}/session.json`;
		const disk = JSON.parse(await Deno.readTextFile(path));
		disk.workspaceAdoption = "available";
		await Deno.writeTextFile(path, JSON.stringify(disk) + "\n");
		assertEquals(await refused(() => DurableRoomsSessionState.open(directory)), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
