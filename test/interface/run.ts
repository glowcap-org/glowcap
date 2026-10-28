// `zig build interface-conversation-check` passes the built Tasks server. The
// existing demo supervisor owns announcements, client deadlines, and cleanup.
import { runCrossLangDemo } from "../../apps/_demo/orchestrator.ts";

if (Deno.args.length !== 1) throw new Error("expected Tasks server path");
const data = await Deno.makeTempDir({ prefix: "glowcap-interface-" });
await runCrossLangDemo(
	{
		label: "interface conversation",
		serverNoun: "server",
		clientNoun: "proof",
		server: { cmd: Deno.args[0], args: () => [`--data=${data}`, "--port=0"] },
		listenPattern: /TASKS-SERVER-LISTENING (\d+) (\S+)/,
		listenMiss: "Tasks server did not announce its board",
		cleanup: () => Deno.remove(data, { recursive: true }),
		roster: () =>
			Promise.resolve({
				participants: [{
					name: "generated Rust",
					cmd: `${Deno.cwd()}/test/interface/rust/target/debug/interface-conversation-proof`,
					argv: (port, [name]) => [String(port), name],
				}],
				skipped: [],
			}),
		failLine: "generated Rust conversation proof failed",
		okLine: () => "generated Rust: creation, replay, callback, pending ownership, and refusals passed",
	},
	0,
	false,
);
