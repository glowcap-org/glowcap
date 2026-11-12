// The normal Tasks server and each application facade, without receipt mocks.
import { runCrossLangDemo } from "../_demo/orchestrator.ts";

if (Deno.args.length !== 1) throw new Error("expected Tasks server path");
const data = await Deno.makeTempDir({ prefix: "glowcap-task-mutations-" });
await runCrossLangDemo(
	{
		label: "Tasks mutations",
		serverNoun: "server",
		clientNoun: "client",
		server: { cmd: Deno.args[0], args: () => [`--data=${data}`, "--port=0"] },
		listenPattern: /TASKS-SERVER-LISTENING (\d+) (\S+) (\S+)/,
		listenMiss: "Tasks server did not announce its board",
		cleanup: () => Deno.remove(data, { recursive: true }),
		roster: () =>
			Promise.resolve({
				participants: [
					{
						name: "TypeScript",
						cmd: "deno",
						argv: (
							_port,
							[name, locator],
						) => [
							"run",
							"--allow-ffi",
							"--allow-read",
							"--allow-net=127.0.0.1",
							"--allow-env",
							"apps/tasks/deno/mutation_test.ts",
							locator,
							name,
						],
					},
					{
						name: "Python",
						cmd: "python3",
						argv: (_port, [name, locator]) => ["apps/tasks/python/mutation_test.py", locator, name],
					},
					{
						name: "Racket",
						cmd: "racket",
						argv: (_port, [name, locator]) => ["-y", "apps/tasks/racket/mutation-test.rkt", locator, name],
					},
					{
						name: "Racket watcher startup",
						cmd: "racket",
						argv: (_port, [name, locator]) => ["-y", "apps/tasks/racket/watcher-test.rkt", locator, name],
					},
				],
				skipped: [],
			}),
		failLine: "Tasks mutation ordering failed",
		okLine: () => "Tasks mutation ordering passed",
	},
	0,
	false,
);
