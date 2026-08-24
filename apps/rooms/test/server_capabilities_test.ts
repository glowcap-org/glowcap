// The capability printer: the state directory's swiss numbers, readable any
// time, in the boot block's own token lines.

import { BOOT_CAPS } from "../lib/boot_caps.ts";
import { capabilityLines } from "../server/capabilities.ts";
import { assert } from "./support/rooms_server.ts";

Deno.test("the printer answers minted, debris, and absent capabilities apart", async () => {
	const state = await Deno.makeTempDir();
	const swiss = "ab".repeat(32);
	await Deno.writeTextFile(`${state}/${BOOT_CAPS.diagnostics.file}`, `${swiss}\n`);
	await Deno.writeTextFile(`${state}/${BOOT_CAPS.viz.file}`, "not-a-swiss\n");
	const lines = await capabilityLines(state);
	assert(
		lines.includes(`${BOOT_CAPS.diagnostics.token} ${swiss}`),
		"a minted swiss does not print as its token line",
	);
	const vizLine = lines.find((line) => line.startsWith(BOOT_CAPS.viz.token));
	assert(vizLine !== undefined && vizLine.includes("debris"), "state debris was printed as a capability");
	const ircLine = lines.find((line) => line.startsWith(BOOT_CAPS.irc.token));
	assert(
		ircLine !== undefined && ircLine.includes("not minted"),
		"an absent capability does not say it was never minted",
	);
	assert(lines.length === Object.keys(BOOT_CAPS).length, "one line per capability, whatever the state holds");
});
