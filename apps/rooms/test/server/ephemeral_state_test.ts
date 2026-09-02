// Hermetic room servers must not inherit a live `GLOWCAP_ROOMS_STATE` from
// the pane that launched the suite. Deno overlays `env` onto the parent
// unless `clearEnv` is set, so a copied map with the key deleted is not enough.

import { assert, withServer } from "../support/rooms_server.ts";

Deno.test("an ephemeral room server does not inherit the pane's rooms-state directory", async () => {
	const previous = Deno.env.get("GLOWCAP_ROOMS_STATE");
	Deno.env.set("GLOWCAP_ROOMS_STATE", ".local/rooms-state");
	try {
		await withServer((port) => {
			assert(port > 0, "the ephemeral server never announced a port");
			return Promise.resolve();
		});
	} finally {
		if (previous == null) Deno.env.delete("GLOWCAP_ROOMS_STATE");
		else Deno.env.set("GLOWCAP_ROOMS_STATE", previous);
	}
});
