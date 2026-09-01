import type { BoundDurableRoomsSession } from "../../session/bind.ts";
import type { DurableRoomsRuntime } from "../../session/runtime.ts";
import type { DurableRoomsSessionState } from "../../session/state.ts";
import type { RoomsSessionGrantView } from "../../lib/session/client.ts";
import { InProcessAttachedRemote } from "../../web/ui/session/local_remote.ts";
import { fixtureSturdyref } from "../support/workspace.ts";
import { assertEquals } from "../assert.ts";

const peer = "ocapn://session.iroh";
const admin = fixtureSturdyref(peer, "admin-root");
const grant = fixtureSturdyref(peer, "issued-grant");
const unknown = fixtureSturdyref(peer, "unknown-swiss");
const otherPeer = fixtureSturdyref("ocapn://other.iroh", "admin-root");

function remote(published: readonly string[] = []): InProcessAttachedRemote {
	return new InProcessAttachedRemote(
		{
			sturdyref: admin,
			grants: {
				list: () => published.map((sturdyref) => ({ sturdyref }) as RoomsSessionGrantView),
			},
			release() {},
		} as unknown as BoundDurableRoomsSession,
		{} as DurableRoomsRuntime,
		{} as DurableRoomsSessionState,
	);
}

async function refusal(work: () => Promise<void>): Promise<string> {
	try {
		await work();
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

Deno.test("a hosted session answers for its administrator capability", async () => {
	await remote().verifySibling(admin);
});

Deno.test("a hosted session answers for a grant it still publishes", async () => {
	await remote([grant]).verifySibling(grant);
});

Deno.test("a hosted session refuses a swiss it has not published", async () => {
	assertEquals(
		await refusal(() => remote([grant]).verifySibling(unknown)),
		"that capability is not published by this session",
	);
});

Deno.test("a hosted session refuses a capability for another peer", async () => {
	assertEquals(
		await refusal(() => remote().verifySibling(otherPeer)),
		"that capability names a different session peer",
	);
});
