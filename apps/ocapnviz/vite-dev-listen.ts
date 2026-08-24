/**
 * Bind address and Host-header policy for the Vite dev server.
 *
 * Loopback on a bare host, so a laptop run exposes nothing to its LAN. The
 * devcontainer sets `OCAPNVIZ_HOST=0.0.0.0` in its compose file, because a
 * Docker-published port reaches only a wide bind inside the container.
 *
 * Vite's Host-header allowlist is a second gate, against DNS rebinding, not a
 * bind. `localhost` is always allowed. A published port arrives with whatever
 * name the operator typed — a `.local` hostname, a LAN IP, a forwarded editor
 * URL — and cataloging those names in the repo would pin one machine. A wide
 * bind already accepted unknown TCP clients; `allowedHosts: true` is the HTTP
 * face of that same decision. Loopback keeps Vite's default allowlist.
 */

export type DevListen = {
	host: string;
	allowedHosts?: true;
};

const LOOPBACK = new Set(["127.0.0.1", "localhost", "::1"]);

/** Resolve `OCAPNVIZ_HOST` into Vite `server.host` / `server.allowedHosts`. */
export function devListen(host: string | undefined): DevListen {
	const bind = host?.trim() || "127.0.0.1";
	if (LOOPBACK.has(bind)) return { host: bind };
	return { host: bind, allowedHosts: true };
}
