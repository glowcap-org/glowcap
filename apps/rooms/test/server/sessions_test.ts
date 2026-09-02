import { CLOSED, INTERNAL, IO } from "@glowcap/abi";
import { GlowcapError, type Session } from "@glowcap/runtime";
import { routinePeerDisconnect } from "../../lib/session_failure.ts";
import { RoomServer } from "../../server/room_server.ts";
import { assertEquals } from "../assert.ts";

Deno.test("member transport loss is an ordinary accepted-session end", () => {
	assertEquals(routinePeerDisconnect(new GlowcapError(IO, "session failed: ConnectionLost")), true);
	assertEquals(routinePeerDisconnect(new GlowcapError(CLOSED, "the peer closed")), true);
	assertEquals(routinePeerDisconnect(new GlowcapError(IO, "session failed: ReadFailed")), false);
	assertEquals(routinePeerDisconnect(new GlowcapError(INTERNAL, "dispatch invariant")), false);
	assertEquals(routinePeerDisconnect(new Error("application behavior failed")), false);
});

function controlledSession(transport: string): { session: Session; closes: () => number } {
	let finish!: () => void;
	let closeCount = 0;
	const served = new Promise<void>((resolve) => {
		finish = resolve;
	});
	const session = {
		sessionOpen: true,
		transportName: transport,
		onClose: () => () => {},
		serve: () => served,
		close: () => {
			closeCount += 1;
			finish();
			return Promise.resolve();
		},
	} as unknown as Session;
	return { session, closes: () => closeCount };
}

async function* one(session: Session): AsyncGenerator<Session> {
	yield session;
}

Deno.test("room servers inventory and disconnect accepted sessions independently", async () => {
	const leftServer = new RoomServer();
	const rightServer = new RoomServer();
	const left = leftServer.sessions;
	const right = rightServer.sessions;
	const alice = controlledSession("left");
	const bob = controlledSession("right");
	await left.serve(one(alice.session));
	await right.serve(one(bob.session));

	const aliceId = left.operatorIdFor(alice.session);
	const bobId = right.operatorIdFor(bob.session);
	if (aliceId === null || bobId === null) throw new Error("an accepted session has no operator identity");
	assertEquals(left.operatorIdFor(bob.session), null);
	assertEquals(right.operatorIdFor(alice.session), null);
	assertEquals([...left.operatorFaces(bob.session)].map((row) => row.build().transport), ["left"]);
	assertEquals([...right.operatorFaces(alice.session)].map((row) => row.build().transport), ["right"]);

	assertEquals(left.disconnect(aliceId, bob.session), true);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(alice.closes() > 0, true);
	assertEquals(left.byOperatorId(aliceId), null);
	assertEquals(right.byOperatorId(bobId), bob.session);
	assertEquals(bob.closes(), 0);

	assertEquals(right.disconnect(bobId, alice.session), true);
	await new Promise((resolve) => setTimeout(resolve, 0));
});
