// A real Spritely Goblins vat enters a room through a pancake directory's
// foreign publication. The source and destination are separate pancake peers:
// the destination hands the room through ordinary three-party handoff, lowers
// its source-authored route to Goblins' v1.0/Syrup floor, and leaves the two
// members talking directly. Revoking discovery afterwards must not revoke the
// room reference Goblins already received.

import { runChild } from "../../apps/_demo/orchestrator.ts";
import { loopbackTcpDesignator, roomsHost } from "../../apps/rooms/lib/locator.ts";
import { Directory, DirectoryPeering, Room } from "../../apps/rooms/lib/room_client.ts";
import { assert, TestRuntimeScope, withPeeringServer, withServer } from "../../apps/rooms/test/support/rooms_server.ts";
import { nextMessage } from "../../apps/rooms/test/support/subscribe.ts";

const ROOT = new URL("../../", import.meta.url).pathname;
const MEMBER = new URL("../../conformance/goblins-peer/racket/rooms-member.rkt", import.meta.url).pathname;
const ROOM = "goblins-peering";
const LISTED_AS = "through-peering";
const OWNER = "pancake-owner";
const GOBLINS = "goblins-visitor";
const FROM_GOBLINS = "reached through the foreign listing";
const AFTER_REVOKE = "the handed room still works after revoke";

const runtimes = new TestRuntimeScope();
let failed = false;
try {
	await withServer(async (sourcePort) => {
		await withPeeringServer(async (destinationPort, peeringSwiss) => {
			const host = roomsHost();
			const connect = (locator: string) => Directory.connect(locator, (address) => runtimes.dial(address, host));
			const source = await connect(loopbackTcpDesignator(sourcePort));
			const publisher = await connect(loopbackTcpDesignator(destinationPort));
			const owner = await Room.subscribe(source.session, await source.open(ROOM), OWNER);
			const peering = await DirectoryPeering.fetch(publisher, peeringSwiss);
			const publication = await peering.publish(LISTED_AS, owner, source);

			const goblins = runChild(
				"racket",
				[
					"-y",
					MEMBER,
					loopbackTcpDesignator(destinationPort),
					LISTED_AS,
					GOBLINS,
					FROM_GOBLINS,
					OWNER,
				],
				ROOT,
			);

			const arrived = await nextMessage(
				owner,
				(message) => message.from === GOBLINS && message.text === FROM_GOBLINS,
			);
			assert(arrived.text === FROM_GOBLINS, "the source room never heard the Goblins member");

			// Discovery and already-handed authority have different lifetimes.
			await publication.revoke();
			assert((await publisher.list()).length === 0, "revocation left the foreign listing discoverable");
			await owner.say(AFTER_REVOKE);

			const result = await goblins;
			console.log(result.out.trimEnd());
			assert(result.code === 0 && result.out.includes("ROOMS OK"), "the Goblins member did not finish");
			assert(
				result.out.includes(AFTER_REVOKE),
				"the Goblins member lost its already-handed room when discovery was revoked",
			);

			await peering.close();
			await owner.leave();
			await publisher.close();
			await source.close();
		});
	});
	console.log("GOBLINS ROOMS PEERING OK: baseline handoff, exact revoke, handed authority still live");
} catch (error) {
	failed = true;
	console.error(`GOBLINS ROOMS PEERING FAILED: ${error instanceof Error ? error.message : error}`);
} finally {
	await runtimes.close();
}

Deno.exit(failed ? 1 : 0);
