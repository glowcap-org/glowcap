// Share takes live directory sessions instead of closing them.

import { assertEquals } from "./assert.ts";

Deno.test("Share steals live directory sessions without closing the Host transport", async () => {
	const held = await Deno.readTextFile(new URL("../web/ui/net/held_directories.ts", import.meta.url));
	const host = await Deno.readTextFile(new URL("../web/ui/session/host.ts", import.meta.url));
	const connection = await Deno.readTextFile(new URL("../web/ui/net/connection.ts", import.meta.url));
	const reachable = await Deno.readTextFile(new URL("../web/ui/net/reachable.ts", import.meta.url));
	assertEquals(held.includes("keepTransport: true"), true);
	assertEquals(held.includes("stealHeldDirectories"), true);
	assertEquals(held.includes("store.dirNick(page.projection, live.id)"), true);
	assertEquals(host.includes("adoptDirectories(stolen)"), true);
	assertEquals(host.includes("row.directory.close()"), true);
	const connectionWatch = connection.slice(connection.indexOf("next.watch("));
	assertEquals(connectionWatch.includes("if (!isCurrent(session)) return;"), true);
	assertEquals(connection.includes("if (options?.keepTransport) which.keepTransport = true;"), true);
	assertEquals(
		connection.indexOf("if (options?.keepTransport) which.keepTransport = true;") <
			connection.indexOf("which.page.live.dirs.delete(which.id)"),
		true,
	);
	const keep = connection.slice(connection.indexOf("if (!options?.keepTransport)"));
	assertEquals(keep.includes("which.signaling?.close()"), true);
	assertEquals(
		connection.slice(0, connection.indexOf("if (!options?.keepTransport)")).includes("which.signaling?.close()"),
		false,
	);
	const signaling = await Deno.readTextFile(new URL("../lib/signaling.ts", import.meta.url));
	assertEquals(reachable.includes("!session.keepTransport"), true);
	assertEquals(reachable.includes("if (session.keepTransport) return;"), true);
	assertEquals(
		reachable.indexOf("if (session.keepTransport) return;") < reachable.indexOf("serveWebrtcSignaling({"),
		true,
	);
	const offer = reachable.slice(reachable.indexOf("export function offerInboxFor"));
	assertEquals(offer.includes("if (!isCurrent(home)) return;"), true);
	const connect = await Deno.readTextFile(new URL("../session/directory_connection.ts", import.meta.url));
	assertEquals(connect.includes("adoptedRegistrationNick(saved.nick, adopted)"), true);
	assertEquals(connect.includes('if (nick !== "")'), true);
	const afterSpawn = signaling.slice(signaling.lastIndexOf("session.spawn"));
	assertEquals(afterSpawn.indexOf("opts.dir()") < afterSpawn.indexOf("offerSignaling(inbox)"), true);
	assertEquals(afterSpawn.includes("opts.dir()"), true);
});
