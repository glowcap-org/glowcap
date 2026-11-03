// The one reader of a child's `ROOMS-*-LISTENING` announcement.
//
// Every Rooms executable prints one flush-left token line on stdout once it is
// reachable. A proof therefore asks for port 0 and reads the port the kernel
// chose instead of choosing a number ahead of the bind, where any other bind
// could take it first. The child's stdout must be piped. A child that exits
// first reports its status and, when its stderr is piped, what it said, so the
// failure names the process rather than the deadline.
import { within } from "./wait.ts";

export interface Announcement {
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
	const status = await proc.status;
	let said = "";
	try {
		said = (await new Response(proc.stderr).text()).trim();
	} catch {
		// stderr was not piped, so the status is all there is to report
	}
	throw new Error(`${who} exited ${status.code} before announcing${said === "" ? "" : `: ${said}`}`);
}

/** The announced token read as a TCP port. */
export async function readAnnouncedPort(proc: Deno.ChildProcess, announcement: Announcement): Promise<number> {
	const announced = await readAnnounced(proc, announcement);
	const port = Number(announced);
	if (!Number.isInteger(port) || port <= 0 || port > 65535) {
		throw new Error(`${announcement.who} announced ${announced}, not a TCP port`);
	}
	return port;
}

/** Keep a child's stdout flowing after its announcement was read.
 *
 * A pipe nobody reads fills its 64 KiB buffer and blocks the child on its next
 * print, and `rooms-web` relays everything its room server prints. Call this
 * once the announcement is read and only for a child whose stdout the caller
 * reads no further. */
export function drainStdout(proc: Deno.ChildProcess): void {
	proc.stdout.pipeTo(new WritableStream()).catch(() => {
		// tolerant: a child killed mid-write errors the pipe, and nothing it printed after its announcement is wanted
	});
}
