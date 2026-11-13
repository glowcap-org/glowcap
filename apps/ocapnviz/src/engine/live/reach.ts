/**
 * Which trace endpoints a page may dial, and what a browser puts in the way.
 *
 * A trace endpoint speaks WebSocket without TLS. A browser blocks that socket
 * when the page loaded over https, unless it goes to the computer's own
 * address, and its error names neither the host nor the reason. The refusal is
 * decided here, before a socket is asked for, so the reader is told which
 * address the page could not reach.
 *
 * A browser may also ask the person before a website reaches their own
 * computer. A socket it blocks for that reason fails like a server that is
 * not running, and `localNetworkBlock` asks the browser what it holds.
 */

/** The trace is not at this computer's own address and this page loaded over
 * https. */
export class TraceOutOfReach extends Error {
	constructor(readonly host: string) {
		super(
			`A page loaded over https reaches a trace only at this computer's own address, such as 127.0.0.1 or localhost, and ${host} is not one.`,
		);
		this.name = "TraceOutOfReach";
	}
}

/** `localhost` and its subdomains, the IPv4 loopback block, and IPv6 loopback
 * with or without the brackets a URL gives it. */
const OWN_ADDRESS = /^(localhost|.+\.localhost|127(\.\d{1,3}){3}|\[::1\]|::1)$/i;

/** The WebSocket address that carries a dial to `host:port`. The trace is
 * fetched in CapTP, which presents its secret there, so the address carries
 * none. A locator names an IPv6 host bare, and a URL holds one in brackets.
 * Throws `TraceOutOfReach` when `pageProtocol` forbids the host. */
export function traceSocketUrl(pageProtocol: string, host: string, port: number): string {
	if (pageProtocol === "https:" && !OWN_ADDRESS.test(host)) throw new TraceOutOfReach(host);
	const authority = host.includes(":") && !host.startsWith("[") ? `[${host}]` : host;
	return `ws://${authority}:${port}/captp`;
}

/** The refusal `cause` is or wraps, or null when it is some other failure. */
export function outOfReach(cause: unknown): TraceOutOfReach | null {
	for (let at = cause; at instanceof Error; at = at.cause) {
		if (at instanceof TraceOutOfReach) return at;
	}
	return null;
}

/** What answers a permission question, replaceable in a test. */
interface PermissionsQuery {
	query(descriptor: { name: string }): Promise<{ state: string }>;
}

/** The names a browser guards a website's reach to this computer under, the
 * narrower one first. A browser answers the names it knows. */
const OWN_COMPUTER_PERMISSIONS = ["loopback-network", "local-network-access"];

/** What the browser holds about a website reaching this computer, for a dial
 * from this page that failed. `"denied"` means the browser blocked it.
 * `"prompt"` means the browser has not been answered, and it leaves that
 * standing for a socket it blocked and for a server that is not running
 * alike, so the failure may be either. Null means the browser does not stand
 * in the way: the permission is granted, the browser has none, or the page is
 * not a website loaded over https. Such a page dials only this computer, and
 * a page this computer serves is never guarded. */
export function localNetworkBlock(
	page: { protocol: string; hostname: string } | undefined = globalThis.document?.location,
	permissions: PermissionsQuery | undefined = globalThis.navigator?.permissions,
): Promise<"denied" | "prompt" | null> | null {
	if (page == null || permissions == null) return null;
	if (page.protocol !== "https:" || OWN_ADDRESS.test(page.hostname)) return null;
	return held(permissions);
}

async function held(permissions: PermissionsQuery): Promise<"denied" | "prompt" | null> {
	for (const name of OWN_COMPUTER_PERMISSIONS) {
		try {
			const { state } = await permissions.query({ name });
			return state === "denied" || state === "prompt" ? state : null;
		} catch {
			// A browser refuses the question for a name it does not know.
		}
	}
	return null;
}
