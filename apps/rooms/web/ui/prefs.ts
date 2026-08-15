/// <reference lib="dom" />
// Direct-message transport and the ocapnviz WebSocket.
//
// The address bar wins when it names a value, so a test or a shared link keeps
// doing what it says. When the URL is silent, the last choice this browser
// remembered is used. Settings writes both, then reloads: the advertised DM
// locator and the viz tap are decided when the peer opens, not mid-session.

export type DmMode = "webrtc" | "relay";

const KEY = {
	dm: "rooms.dm",
	viz: "rooms.viz",
} as const;

const LS = {
	get(k: string): string | null {
		try {
			return localStorage.getItem(k);
		} catch {
			return null;
		}
	},
	set(k: string, v: string): void {
		try {
			localStorage.setItem(k, v);
		} catch { /* storage disabled (private mode); ignore */ }
	},
	remove(k: string): void {
		try {
			localStorage.removeItem(k);
		} catch { /* private mode */ }
	},
};

/** Resolve DM transport from a search string and a stored preference. */
export function dmFrom(search: URLSearchParams, stored: string | null): DmMode {
	const q = search.get("dm");
	if (q === "relay") return "relay";
	if (q === "webrtc") return "webrtc";
	return stored === "relay" ? "relay" : "webrtc";
}

/** Resolve the viz override. `null` means "ask this page's server". An empty
 * `?viz=` is an explicit blank, not "use storage". */
export function vizFrom(search: URLSearchParams, stored: string | null): string | null {
	if (search.has("viz")) return search.get("viz");
	return stored;
}

export function dmTransport(): DmMode {
	return dmFrom(new URLSearchParams(location.search), LS.get(KEY.dm));
}

export function vizOverride(): string | null {
	return vizFrom(new URLSearchParams(location.search), LS.get(KEY.viz));
}

export function current(): { dm: DmMode; viz: string } {
	return { dm: dmTransport(), viz: vizOverride() ?? "" };
}

/** Build the WebSocket URL this page would use for a `/viz` port. */
export function vizWsUrl(
	port: string,
	loc: { protocol: string; hostname: string },
): string | null {
	if (!/^[0-9]+$/.test(port)) return null;
	const proto = loc.protocol === "https:" ? "wss://" : "ws://";
	return `${proto}${loc.hostname}:${port}/`;
}

/** What a blank viz field means: this page's `/viz` answer, or null if none. */
export async function advertisedViz(): Promise<string | null> {
	try {
		const res = await fetch("/viz");
		if (!res.ok) {
			await res.body?.cancel();
			return null;
		}
		return vizWsUrl((await res.text()).trim(), location);
	} catch {
		return null;
	}
}

/** The room directory this page is serving, from `/locator`. */
export async function directoryLocator(): Promise<string | null> {
	try {
		const res = await fetch("/locator");
		const text = (await res.text()).trim();
		if (!res.ok || text.length === 0) return null;
		return text;
	} catch {
		return null;
	}
}

/** Write `dm` / `viz` onto `url`, leaving any other query alone. WebRTC is the
 * default, so it comes off the address rather than sitting there as `?dm=webrtc`. */
export function writeSearch(url: URL, next: { dm: DmMode; viz: string }): void {
	if (next.dm === "relay") url.searchParams.set("dm", "relay");
	else url.searchParams.delete("dm");
	const viz = next.viz.trim();
	if (viz) url.searchParams.set("viz", viz);
	else url.searchParams.delete("viz");
}

/** Remember the choice, put it on the URL so a reload and a bookmark agree, and
 * reload so the peer opens with the new locator and viz tap. */
export function apply(next: { dm: DmMode; viz: string }): void {
	const viz = next.viz.trim();
	LS.set(KEY.dm, next.dm);
	if (viz) LS.set(KEY.viz, viz);
	else LS.remove(KEY.viz);
	const url = new URL(location.href);
	writeSearch(url, next);
	history.replaceState(null, "", url);
	location.reload();
}
