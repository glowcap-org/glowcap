// One Goblins rooms-chat vat as the matrix drives it: the Racket process, the
// lines it prints, and the waits on them.

import type { vatTraceEnv } from "../../apps/rooms/test/trace/viewer.ts";
import { until } from "../../apps/rooms/test/support/wait.ts";

const CHAT = new URL("../../conformance/goblins-peer/racket/rooms-chat.rkt", import.meta.url)
	.pathname;
const RACKET_DIR = new URL("../../conformance/goblins-peer/racket/", import.meta.url).pathname;
/** How long the matrix waits on one step of either kind of peer. */
export const WAIT_MS = 60_000;

export class ChatPeer {
	readonly lines: string[] = [];
	readonly errors: string[] = [];
	readonly child: Deno.ChildProcess;
	readonly #writer: WritableStreamDefaultWriter<Uint8Array>;
	readonly #drains: Promise<void>[];
	#compiledRoot: string | null;

	constructor(readonly nick: string, locator: string, room: string, trace: ReturnType<typeof vatTraceEnv>) {
		// Concurrent Racket processes must not replace one shared .zo while its
		// sibling is opening it. A private compiled root keeps startup parallel
		// and leaves the checkout untouched.
		this.#compiledRoot = Deno.makeTempDirSync({ prefix: "glowcap-rooms-racket-" });
		this.child = new Deno.Command("racket", {
			args: ["-y", CHAT, locator, room, nick],
			cwd: RACKET_DIR,
			env: {
				...trace,
				// The trailing empty path is Racket's `same` fallback: reuse
				// installed package bytecode, but write checkout-local bytecode only
				// into this peer's private first root.
				PLTCOMPILEDROOTS: `${this.#compiledRoot}${Deno.build.os === "windows" ? ";" : ":"}`,
			},
			stdin: "piped",
			stdout: "piped",
			stderr: "piped",
		}).spawn();
		this.#writer = this.child.stdin.getWriter();
		this.#drains = [
			this.#drain(this.child.stdout, this.lines, ""),
			this.#drain(this.child.stderr, this.errors, " stderr"),
		];
	}

	#drain(stream: ReadableStream<Uint8Array>, into: string[], suffix: string): Promise<void> {
		return (async () => {
			const decoder = new TextDecoder();
			let buffered = "";
			for await (const chunk of stream) {
				buffered += decoder.decode(chunk, { stream: true });
				const lines = buffered.split("\n");
				buffered = lines.pop() ?? "";
				for (const line of lines) {
					into.push(line);
					console.log(`  [${this.nick}${suffix}] ${line}`);
				}
			}
			buffered += decoder.decode();
			if (buffered.length > 0) {
				into.push(buffered);
				console.log(`  [${this.nick}${suffix}] ${buffered}`);
			}
		})().catch((err) => {
			this.errors.push(String(err));
		});
	}

	async ready(room: string): Promise<void> {
		await this.wait(new RegExp(`^\\* you are in ${room}$`), `join #${room}`);
		await this.wait(/granted you the name/, "DM registration");
	}

	async send(line: string): Promise<number> {
		const cursor = this.lines.length;
		await this.#writer.write(new TextEncoder().encode(`${line}\n`));
		return cursor;
	}

	async command(line: string, expected: RegExp, what: string): Promise<void> {
		const cursor = await this.send(line);
		await this.wait(expected, what, cursor);
	}

	async wait(pattern: RegExp, what: string, cursor = 0): Promise<void> {
		await until(
			() => this.lines.slice(cursor).some((line) => pattern.test(line)),
			`${this.nick} to ${what}`,
			WAIT_MS,
		);
	}

	/** Wait until `/dms` lists `nick`, as a person checks before messaging: the
	 * directory refuses a direct message to a member whose registration it does
	 * not hold yet, and this list is the directory's own account of who it holds. */
	async reaches(nick: string): Promise<void> {
		const listed = new RegExp(`^\\* ${nick}$`);
		const deadline = Date.now() + WAIT_MS;
		for (;;) {
			const cursor = await this.send("/dms");
			try {
				await until(
					() => this.lines.slice(cursor).some((line) => listed.test(line)),
					`${this.nick} to list ${nick}`,
					1000,
				);
				return;
			} catch (error) {
				// tolerant: an answer without the name is a list from before the registration, so ask again until the deadline.
				if (Date.now() > deadline) throw error;
			}
		}
	}

	async waitError(pattern: RegExp, what: string, cursor = 0): Promise<void> {
		await until(
			() => this.errors.slice(cursor).some((line) => pattern.test(line)),
			`${this.nick} to ${what}`,
			WAIT_MS,
		);
	}

	assertClean(): void {
		const fatal = this.errors.find((line) =>
			line.includes("invalid-handoff-cert") ||
			this.isSyrupEof(line)
		);
		if (fatal) throw new Error(`${this.nick} reported ${fatal}`);
	}

	assertNoSyrupEof(): void {
		const fatal = this.errors.find((line) => this.isSyrupEof(line));
		if (fatal) throw new Error(`${this.nick} reported ${fatal}`);
	}

	private isSyrupEof(line: string): boolean {
		return line.includes("open-input-bytes: contract violation") ||
			line.includes("expected: bytes?");
	}

	async close(): Promise<void> {
		// best-effort: the child may already have exited, and the status awaited below reports how it ended.
		await this.#writer.close().catch(() => {});
		const status = await this.child.status;
		await Promise.all(this.#drains);
		this.cleanupCompiled();
		if (!status.success) throw new Error(`${this.nick} exited ${status.code}`);
	}

	cleanupCompiled(): void {
		if (this.#compiledRoot === null) return;
		Deno.removeSync(this.#compiledRoot, { recursive: true });
		this.#compiledRoot = null;
	}

	kill(): void {
		try {
			this.child.kill();
		} catch {
			// tolerant: a vat that already exited has nothing left to stop.
		}
	}
}
