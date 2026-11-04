// Session construction keeps the operation failure when retiring its channel fails.
import { CLOSED, DESIGNATOR_SCHEME_ADDRESS } from "@glowcap/abi";
import { GlowcapError, secondaryFailures } from "../errors.ts";
import { Host } from "../host.ts";
import { bareLocator } from "../locator.ts";
import { type Channel, Session } from "../session.ts";
import { assert, assertEquals, assertRejects } from "../../test/assert.ts";

for (const side of ["dial", "accept"] as const) {
	for (const phase of ["open", "handshake"] as const) {
		for (const retirement of ["throw", "reject"] as const) {
			Deno.test(`${side} preserves ${phase} failure when channel retirement ${retirement}s`, async () => {
				const host = new Host();
				const primary = Object.freeze(new Error("handshake read failed"));
				const cleanup = new Error("channel retirement failed");
				let closes = 0;
				const channel: Channel = {
					read: () => Promise.reject(primary),
					write: () => Promise.resolve(),
					close() {
						closes++;
						if (retirement === "reject") return Promise.reject(cleanup);
						throw cleanup;
					},
				};
				if (phase === "open") await host.close();
				try {
					const establish = side === "dial"
						? Session.establishDialedLocator(host, bareLocator("tcp", "127.0.0.1:1"), channel, 1000, null)
						: Session.establishAccepted(host, {
							transport: "tcp",
							designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
							serverDesignator: "127.0.0.1:1",
							channel,
							verifiedChannelKey: null,
						}, 1000);
					const observed = await assertRejects(() => establish);
					if (phase === "open") {
						assert(
							observed instanceof GlowcapError && observed.code === CLOSED,
							"cleanup replaced Host refusal",
						);
					} else {
						assertEquals(observed, primary);
					}
					assertEquals(closes, 1);
					const secondary = secondaryFailures(observed);
					assertEquals(secondary.length, 1);
					assertEquals(secondary[0], cleanup);
				} finally {
					await host.close();
				}
				assertEquals(closes, 1);
			});
		}
	}
}
