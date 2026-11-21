/// <reference lib="dom" />
// Browser permission to reach a more private network from this page.

/** The browser's answer on reaching the local network from this page: asked
 * on the first try, refused, allowed, or null in a browser that never asks. */
export type LocalNetworkPermission = LocalNetworkRefusal | "granted" | null;
/** The two answers under which the browser lets nothing through. */
export type LocalNetworkRefusal = "prompt" | "denied";

/** The one question asked of the browser's permissions. The name is a
 * string because lib.dom lags the names browsers answer to. */
export interface PermissionsQuery {
	query(descriptor: { name: string }): Promise<{ state: PermissionState }>;
}

/** Where a host stands to the browser: this computer, the person's own
 * network, or the public internet, by the host name or address alone. */
export type AddressSpace = "loopback" | "local" | "public";

export function addressSpace(hostname: string): AddressSpace {
	const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
	if (host === "localhost" || host.endsWith(".localhost") || host === "::1") return "loopback";
	const v4 = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
	if (v4 != null) {
		const [a, b] = [Number(v4[1]), Number(v4[2])];
		if (a === 127) return "loopback";
		const local = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
			(a === 169 && b === 254);
		return local ? "local" : "public";
	}
	return /^f[cd][0-9a-f]{2}:/.test(host) || /^fe[89ab][0-9a-f]:/.test(host) ? "local" : "public";
}

/** Nearer to the person is more private. */
const PRIVACY: Record<AddressSpace, number> = { loopback: 0, local: 1, public: 2 };

/** Whether reaching `target` from this page crosses into a more private
 * space (a public page to the person's network or computer, or a page on the
 * network to this computer), which a browser may guard. */
export function reachesLocalNetwork(target: URL, page: string | undefined = globalThis.location?.hostname): boolean {
	return page != null && PRIVACY[addressSpace(target.hostname)] < PRIVACY[addressSpace(page)];
}

/** Why a browser on a page from the public internet may be the reason a local
 * server does not answer: its local network permission, when reaching
 * `target` crosses into the local network, else null. Chrome asks the person
 * on the first read and refuses in silence until they allow it; a browser
 * without the permission answers null. */
export function localNetworkBlock(
	target: URL,
	{ page = globalThis.location?.hostname, permissions = globalThis.navigator?.permissions }: {
		page?: string;
		permissions?: PermissionsQuery;
	} = {},
): Promise<LocalNetworkPermission> {
	if (permissions == null || !reachesLocalNetwork(target, page)) return Promise.resolve(null);
	return permissions.query({ name: "local-network-access" }).then((status) => status.state, () => null);
}
