// Print the operator capabilities this state directory holds, any time.
//
// The boot block prints each swiss number once, at startup, and a deployment
// reading it back through `docker compose logs` is fishing in scrollback for
// a fact that lives on disk: `persistentSwiss` keeps every minted swiss as
// one file per capability under `GLOWCAP_ROOMS_STATE`, which is what lets a
// restart republish the same one. This reads those files and prints the same
// flush-left token lines the boot block does, so the grep contract holds
// wherever the lines came from.
//
//     GLOWCAP_ROOMS_STATE=/state deno run --allow-read --allow-env \
//       apps/rooms/server/capabilities.ts
//
// In the deploy container: `docker compose exec rooms deno run --allow-read
// --allow-env --no-lock /repo/apps/rooms/server/capabilities.ts`. Holding
// these lines is holding the capabilities; that is the whole of the access
// control, stated in the deploy README.

import { ALL_BOOT_CAPS } from "../lib/boot_caps.ts";
import { readBoundedText } from "../lib/durable_file.ts";

/** The token lines for whatever `directory` holds: one per minted
 * capability, and a plain sentence for each capability with no swiss there,
 * so "not minted" reads as an answer rather than an absence. */
export async function capabilityLines(directory: string): Promise<string[]> {
	const lines: string[] = [];
	for (const cap of ALL_BOOT_CAPS) {
		let swiss = "";
		try {
			swiss = (await readBoundedText(`${directory}/${cap.file}`, 256, `${cap.label} capability state`)).trim();
		} catch {
			// No file is a capability that was never enabled here.
		}
		if (/^[0-9a-f]{64}$/.test(swiss)) {
			lines.push(`${cap.token} ${swiss}`);
		} else if (swiss !== "") {
			lines.push(`${cap.token} (the state file holds debris, not a swiss; re-enable ${cap.flag} to remint)`);
		} else {
			lines.push(`${cap.token} (not minted here; start with ${cap.flag} to mint it)`);
		}
	}
	return lines;
}

if (import.meta.main) {
	const directory = Deno.args[0] ?? Deno.env.get("GLOWCAP_ROOMS_STATE");
	if (directory === undefined || directory === "") {
		console.error(
			"capabilities: say where the state lives — set GLOWCAP_ROOMS_STATE or pass the directory as the argument",
		);
		Deno.exit(2);
	}
	console.log((await capabilityLines(directory)).join("\n"));
}
