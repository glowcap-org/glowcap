// Private-room durable link reachability and restart behavior.

import { Directory, Room, roomCalledAs } from "../../lib/room/client.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { newManagedRoomId } from "../../lib/limits.ts";
import { PRIVATE_ROOM_POLICY } from "../../lib/room/policy.ts";
import {
	assert,
	assertMatch,
	dial,
	readPort,
	restartStatefulServer,
	roomsTest,
	stablePort,
	startStatefulServer,
	stopServer,
	until,
} from "../support/rooms_server.ts";

roomsTest("a private room mints a link that reaches it, and nothing else does", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-private-" });
	const port = stablePort();
	let server = startStatefulServer(port, stateDirectory);
	try {
		await readPort(server);
		const locator = loopbackTcpDesignator(port);
		const dir = await Directory.connect(locator, (address) => dial(address));
		const atomicKey = newManagedRoomId();
		const atomicLink = await dir.openPrivateLink(atomicKey);
		assert(await dir.openPrivateLink(atomicKey) === atomicLink, "the atomic private link changed on retry");
		const rawKey = newManagedRoomId();
		const raw = await dir.openManaged("unjoined", { policy: PRIVATE_ROOM_POLICY, roomId: rawKey });
		const rawLink = raw.roomLink;
		dir.session.release(raw.room);
		const rawGuest = await Directory.connect(locator, (address) => dial(address));
		const rawAgain = await rawGuest.session.enliven(rawLink);
		assert(
			await roomCalledAs(rawGuest.session, rawAgain) === "unjoined",
			"an unjoined private room link died with its temporary occurrence",
		);
		rawGuest.session.release(rawAgain);
		await rawGuest.close();
		const recoveryKey = newManagedRoomId();
		const first = await dir.openManaged("plans", { policy: PRIVATE_ROOM_POLICY, roomId: recoveryKey });
		let room = await Room.subscribe(dir.session, first.room, "ada");
		await room.takeManager(first.managerLink);
		const link = first.roomLink;
		const repeatedManaged = await dir.openManaged("plans", { policy: PRIVATE_ROOM_POLICY, roomId: recoveryKey });
		const repeated = await Room.subscribe(dir.session, repeatedManaged.room, "ada");
		await repeated.takeManager(repeatedManaged.managerLink);
		assert(repeatedManaged.roomLink === link, "repeating a private recovery key opened a different room");
		room.replaced();
		room = repeated;
		assert((await room.called()) === "plans", "a live private room did not say what it is called");
		assert((await room.isPrivate()) === true, "a live private room did not say it is unlisted");
		let byName = "";
		try {
			await dir.link("plans");
		} catch (error) {
			byName = error instanceof Error ? error.message : String(error);
		}
		assertMatch(byName, /no room named "plans"/);

		const guest = await Directory.connect(locator, (address) => dial(address));
		const guestRef = await guest.session.enliven(link);
		assert(
			(await roomCalledAs(guest.session, guestRef)) === "plans",
			"enlivening a live private room's link did not say what the room is called",
		);
		const asGuest = await Room.subscribe(guest.session, guestRef, "bo");
		await until(() => asGuest.listed != null, "subscribe did not say whether the occupancy is listed");
		assert(asGuest.listed === false, "a private room's welcome did not say it is unlisted");
		await asGuest.say("here by the link alone");
		await room.leave();
		await asGuest.leave();
		await dir.close();
		await guest.close();

		await stopServer(server);
		server = await restartStatefulServer(port, stateDirectory);
		const later = await Directory.connect(locator, (address) => dial(address));
		assert(
			await later.openPrivateLink(atomicKey) === atomicLink,
			"the atomic private link changed across server restart",
		);
		const recoveredManaged = await later.openManaged("plans", {
			policy: PRIVATE_ROOM_POLICY,
			roomId: recoveryKey,
		});
		const recovered = await Room.subscribe(later.session, recoveredManaged.room, "ada");
		assert(recoveredManaged.roomLink === link, "a private recovery key changed across server restart");
		await recovered.leave();
		const again = await Room.subscribe(
			later.session,
			await later.session.enliven(link),
			"ada",
		);
		await again.say("still here");
		await again.leave();
		await later.close();
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});
