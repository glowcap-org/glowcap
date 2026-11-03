// `zig build interface-goblins-check` supplies the real Tasks server artifact.
// The shared demo supervisor owns announcement, child lifetime, and cleanup.
import { runCrossLangDemo } from "../../apps/_demo/orchestrator.ts";

if (Deno.args.length !== 1) throw new Error("expected Tasks server path");
const data = await Deno.makeTempDir({ prefix: "glowcap-interface-goblins-" });
await runCrossLangDemo(
	{
		label: "interface Goblins creation",
		serverNoun: "Tasks server",
		clientNoun: "Goblins caller",
		server: { cmd: Deno.args[0], args: () => [`--data=${data}`, "--port=0"] },
		listenPattern: /TASKS-SERVER-LISTENING (\d+) (\S+)/,
		listenMiss: "Tasks server did not announce its board",
		cleanup: () => Deno.remove(data, { recursive: true }),
		roster: () =>
			Promise.resolve({
				participants: [{
					name: "plain Goblins",
					cmd: "racket",
					argv: (
						port,
						[name],
					) => ["conformance/goblins-peer/racket/interface-creation-client.rkt", String(port), name],
				}],
				skipped: [],
			}),
		failLine: "plain Goblins creation proof failed",
		okLine: () => "plain Goblins: generated Zig creation arguments, callable result, replay and refusal passed",
	},
	0,
	false,
);
