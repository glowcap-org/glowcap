// The one reader of a child's `ROOMS-*-LISTENING` announcement.
//
// Every Rooms executable prints one flush-left token line on stdout once it is
// reachable. A proof therefore asks for port 0 and reads the port the kernel
// chose instead of choosing a number ahead of the bind, where any other bind
// could take it first. The child's stdout must be piped. A child that exits
// first reports its status and, when its stderr is piped, what it said, so the
// failure names the process rather than the deadline.
import { within } from "./wait.ts";

interface Announcement {
	/** The flush-left token, such as `ROOMS-SERVER-LISTENING`. */
	token: string;
	/** Who is expected to announce, for the sentence a failure reports. */
	who: string;
	withinMs?: number;
}

export async function readAnnounced(proc: Deno.ChildProcess, announcement: Announcement): Promise<string> {
	const { token, who, withinMs = 10_000 } = announcement;
	const reader = proc.stdout.getReader();
	const decoder = new TextDecoder();
	// The whole line, so a chunk that ends mid-value is read on, not returned.
	const pattern = new RegExp(`^${token} (\\S+)\\n`, "m");
	let buf = "";
	let open = true;
	const deadline = Date.now() + withinMs;
	try {
		while (open) {
			const { value, done } = await within(reader.read(), `${who} to announce`, deadline - Date.now());
			if (done) {
				open = false;
				break;
			}
			buf += decoder.decode(value, { stream: true });
			const match = buf.match(pattern);
			if (match != null) return match[1];
		}
	} finally {
		reader.releaseLock();
	}
	throw await exitedBeforeAnnouncing(proc, who);
}

/** The failure for a child that ended before it announced: its exit status and,
 * when its stderr is piped, what it said. */
export async function exitedBeforeAnnouncing(proc: Deno.ChildProcess, who: string): Promise<Error> {
	const status = await proc.status;
	let said = "";
	try {
		said = (await new Response(proc.stderr).text()).trim();
	} catch {
		// stderr was not piped, so the status is all there is to report
	}
	return new Error(`${who} exited ${status.code} before announcing${said === "" ? "" : `: ${said}`}`);
}

/** Every flush-left `ROOMS-*` line a child prints on stdout, read by one reader
 * for the child's whole life. The first line per token is kept, so a token asked
 * for after it printed still answers, and every chunk is passed through to this
 * process's stdout so the run stays observable. A supervisor such as `rooms-web`
 * prints its own block and the lines of the directory it runs this way. */
export class Announcements {
	readonly #lines = new Map<string, string>();
	readonly #waiting = new Map<string, { resolve: (value: string) => void; reject: (error: Error) => void }[]>();
	#ended = false;

	constructor(stdout: ReadableStream<Uint8Array>) {
		this.#read(stdout).catch(() => {
			// tolerant: a child killed mid-write errors the pipe, and the waiters hear that it ended
		}).finally(() => this.#end());
	}

	/** Whether the child's stdout has ended. */
	get ended(): boolean {
		return this.#ended;
	}

	/** The value after `token` on its first line, or a refusal naming `who` when
	 * the child's stdout ends or `withinMs` passes first. */
	line(token: string, who: string, withinMs = 10_000): Promise<string> {
		const kept = this.#lines.get(token);
		if (kept != null) return Promise.resolve(kept);
		if (this.#ended) return Promise.reject(new Error(`${who} ended before announcing ${token}`));
		const waited = new Promise<string>((resolve, reject) => {
			const waiters = this.#waiting.get(token) ?? [];
			waiters.push({ resolve, reject });
			this.#waiting.set(token, waiters);
		});
		return within(waited, `${who} to announce ${token}`, withinMs);
	}

	async #read(stdout: ReadableStream<Uint8Array>): Promise<void> {
		const decoder = new TextDecoder();
		let tail = "";
		for await (const chunk of stdout) {
			await writeAll(Deno.stdout, chunk).catch(() => {
				// tolerant: a closed stdout of this process loses the pass-through, not the reading
			});
			tail += decoder.decode(chunk, { stream: true });
			let newline: number;
			while ((newline = tail.indexOf("\n")) !== -1) {
				this.#line(tail.slice(0, newline));
				tail = tail.slice(newline + 1);
			}
		}
	}

	#line(line: string): void {
		const match = line.match(/^(ROOMS-[A-Z0-9-]+) (.+)$/);
		if (match == null || this.#lines.has(match[1])) return;
		const value = match[2].trim();
		this.#lines.set(match[1], value);
		for (const waiter of this.#waiting.get(match[1]) ?? []) waiter.resolve(value);
		this.#waiting.delete(match[1]);
	}

	#end(): void {
		this.#ended = true;
		for (const [token, waiters] of this.#waiting) {
			for (const waiter of waiters) waiter.reject(new Error(`stdout ended before announcing ${token}`));
		}
		this.#waiting.clear();
	}
}

async function writeAll(out: { write(bytes: Uint8Array): Promise<number> }, bytes: Uint8Array): Promise<void> {
	let written = 0;
	while (written < bytes.length) written += await out.write(bytes.subarray(written));
}

/** The announced token read as a TCP port. */
export async function readAnnouncedPort(proc: Deno.ChildProcess, announcement: Announcement): Promise<number> {
	return asPort(await readAnnounced(proc, announcement), announcement.who);
}

/** `announced` as the TCP port it names, or a refusal naming `who`. */
export function asPort(announced: string, who: string): number {
	const port = Number(announced);
	if (!Number.isInteger(port) || port <= 0 || port > 65535) {
		throw new Error(`${who} announced ${announced}, not a TCP port`);
	}
	return port;
}

/** Keep a child's stdout flowing after its announcement was read.
 *
 * A pipe nobody reads fills its 64 KiB buffer and blocks the child on its next
 * print, and a child keeps printing after its announcement. Call this
 * once the announcement is read and only for a child whose stdout the caller
 * reads no further. */
export function drainStdout(proc: Deno.ChildProcess): void {
	proc.stdout.pipeTo(new WritableStream()).catch(() => {
		// tolerant: a child killed mid-write errors the pipe, and nothing it printed after its announcement is wanted
	});
}
