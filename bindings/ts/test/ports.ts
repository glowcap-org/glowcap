// A loopback port a proof may choose for itself.
//
// A proof never picks a port a child will bind: it asks the child for port 0
// and reads the port the child announces. The kernel hands port 0 requests, and
// every outgoing connection, a number from its ephemeral range, so a number
// chosen ahead of the child's bind from that range can be taken first by any
// other bind or connection on the host.
//
// This is for the few ports a proof must name before a child exists: a server
// that has to come back on the port its clients hold, an address nothing
// listens on, or a front whose advertised route embeds its own port. Those
// numbers come from below the kernel's ephemeral range, where only a process
// that asks for that exact number can take them. Two proofs drawing at the
// same moment can still draw the same number, so each draw is random and
// probed for a free bind. Within one process no number is handed out twice,
// so two names for different ports never alias: a duplicated room port would
// make a second front attach to the first one's room server instead of
// starting its own.

const DEFAULT_EPHEMERAL_LOW = 32768;
const FLOOR = 1024;
const WINDOW = 12_000;
const ATTEMPTS = 64;

const issued = new Set<number>();

/** The low end of the kernel's ephemeral range, or the Linux default when the
 * host does not publish one. */
function ephemeralLow(): number {
	try {
		const [low] = Deno.readTextFileSync("/proc/sys/net/ipv4/ip_local_port_range").trim().split(/\s+/);
		const parsed = Number(low);
		if (Number.isInteger(parsed) && parsed > FLOOR) return parsed;
	} catch {
		// Not Linux, or /proc is not mounted: the default range is the best statement of it.
	}
	return DEFAULT_EPHEMERAL_LOW;
}

/** A loopback port below the ephemeral range that nothing is listening on and
 * this process has not already been handed. A candidate is kept only if a real
 * bind to it succeeds, so a number another process holds is skipped. */
export function nonEphemeralPort(): number {
	const high = ephemeralLow();
	const low = Math.max(FLOOR, high - WINDOW);
	for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
		const port = low + Math.floor(Math.random() * (high - low));
		if (issued.has(port)) continue;
		try {
			Deno.listen({ hostname: "127.0.0.1", port }).close();
			issued.add(port);
			return port;
		} catch (error) {
			if (!(error instanceof Deno.errors.AddrInUse)) throw error;
		}
	}
	throw new Error(`no free port in ${low}-${high - 1}`);
}
