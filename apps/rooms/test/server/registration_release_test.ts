// A nickname registration dies with the connection that made it.
//
// The register verb's own contract says a claim "frees when they disconnect",
// and the operator's inventories draw one row per live claim and per live
// session. Pinned here because the shared-session work moves connections
// between owners: the closed member's rows must leave the registrations and
// sessions inventories, and the freed name must register cleanly from a new
// connection.
//
// Validated against injected defects: a session inventory that never retires
// a served row is caught by the sessions-drain wait on the exact session id,
// and breaking the disconnect flush's dropIntroductions together with the
// dead-holder bypass in registeredByAnother refuses the successor and is
// caught by the re-register. What this test measured itself as not reaching:
// either of those two alone. Every wire verb defends on the registrar's
// sessionOpen and a healthy flush empties the row the bypass would read, so
// each single defect is masked by the other half; the in-process
// introductions table is memory hygiene only an in-process probe can see,
// and disabling dropIntroductions alone left this test green.

import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { Directory } from "../../lib/directory.ts";
import { operatorPage, takeRoomsOperator } from "../../lib/operator.ts";
import { assert, dial, roomsTest, startStatefulServer, stopServer } from "../support/rooms_server.ts";
import { readPort } from "../support/rooms_server.ts";

roomsTest("a closed connection's nickname registration leaves the inventory and frees the name", async () => {
	const stateDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-registration-release-" });
	const port = (49_400 + Math.floor(Math.random() * 900)) | 0;
	const locator = loopbackTcpDesignator(port);
	const server = startStatefulServer(port, stateDirectory, ["--operator"]);
	try {
		await readPort(server);
		const operatorSwiss = (await Deno.readTextFile(`${stateDirectory}/operator`)).trim();
		assert(operatorSwiss !== "", "the operator swiss was not persisted");

		const member = await Directory.connect(locator, (address) => dial(address));
		await member.register("ghost", locator);

		const watcher = await dial(locator);
		watcher.serve().catch(() => {});
		const { cap } = await takeRoomsOperator(watcher, operatorSwiss);
		const claimed = await operatorPage(watcher, cap, "registrations");
		const row = claimed.category === "registrations"
			? claimed.rows.find((entry) => entry.nick === "ghost")
			: undefined;
		assert(row !== undefined, `the live registration was not inventoried: ${JSON.stringify(claimed.rows)}`);
		const memberSessionId = row.sessionId;
		// Provenance: the holder is another connection, and the sessions
		// inventory resolves it. The watcher's own connection is listed too,
		// marked, so a claim held by the asking session can never again read as
		// held by nothing.
		assert(!row.you, "another connection's claim was marked as the watcher's own");
		const peers = await operatorPage(watcher, cap, "sessions");
		assert(
			peers.category === "sessions" && peers.rows.some((entry) => entry.id === memberSessionId && !entry.you),
			"the holder's session was not inventoried for the registration to resolve against",
		);
		assert(
			peers.category === "sessions" && peers.rows.some((entry) => entry.you),
			"the watcher's own connection was not listed",
		);

		await member.close();

		const deadline = Date.now() + 15_000;
		let held = true;
		while (held) {
			const registrations = await operatorPage(watcher, cap, "registrations");
			const sessions = await operatorPage(watcher, cap, "sessions");
			held = (registrations.category === "registrations" &&
				registrations.rows.some((entry) => entry.nick === "ghost")) ||
				(sessions.category === "sessions" && sessions.rows.some((entry) => entry.id === memberSessionId));
			if (held && Date.now() >= deadline) {
				throw new Error("the closed connection's rows stayed in the inventories");
			}
			if (held) await new Promise((resolve) => setTimeout(resolve, 100));
		}

		// The freed name registers cleanly from a new connection.
		const successor = await Directory.connect(locator, (address) => dial(address));
		await successor.register("ghost", locator);
		await successor.close();

		watcher.close();
		await watcher.serve().catch(() => {});
	} finally {
		await stopServer(server);
		await Deno.remove(stateDirectory, { recursive: true });
	}
});
