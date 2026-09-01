// HTTP serving for the rooms web host: the browser bundle, page assets, and
// the byte-relay endpoints. Process flags, room-server supervision, and stop
// live in `serve.ts`; this file is the listener those hand a live locator to.

import { classifyRelayTarget, onionDesignator, type RelayTarget } from "./relay_target.ts";
import { pipeVizSocket } from "./viz_proxy.ts";
import { icePolicy } from "./ice_policy.ts";
import {
	bridgeRendezvous,
	isRendezvousDesignator,
	registerRendezvous,
	relayAllowed,
	relayOriginAllowed,
	relayToTarget,
	type TcpPeer,
} from "./relay.ts";

export type HttpServe = {
	root: string;
	httpPort: number;
	signal: AbortSignal;
	roomPort: string;
	relayTcpPeers: readonly TcpPeer[];
	vizPort: string;
	locator: () => string;
	stop: (code: number) => Promise<never>;
};

export async function prepareAndListen(opts: HttpServe): Promise<void> {
	const ROOT = opts.root;
	const HTTP_PORT = opts.httpPort;
	const shutdown = { signal: opts.signal };
	const ROOM_PORT = opts.roomPort;
	const RELAY_TCP_PEERS = opts.relayTcpPeers;
	const VIZ_PORT = opts.vizPort;
	const stop = opts.stop;
	const roomLocator = () => opts.locator();
	// Public STUN configuration and the private TURN issuer contract are startup
	// state. Parse them before the listener makes a malformed or over-broad
	// answer reachable. Short-lived credentials themselves are minted per `/ice`
	// request; the issuer bearer token never crosses this server boundary.
	const ICE_POLICY = icePolicy({
		stunServers: Deno.env.get("PANCAKE_ROOMS_ICE_SERVERS"),
		turnCredentialsUrl: Deno.env.get("PANCAKE_ROOMS_TURN_CREDENTIALS_URL"),
		turnBearerToken: Deno.env.get("PANCAKE_ROOMS_TURN_BEARER_TOKEN"),
		turnTtlSeconds: Deno.env.get("PANCAKE_ROOMS_TURN_TTL_SECONDS"),
	});

	// One same-origin door per timeline leg: refuse a foreign page, upgrade,
	// and carry the socket to the endpoint with the path and query intact.
	const carryVizSocket = (req: Request, search: string, endpointPath: string): Response => {
		if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
			return new Response("rooms: cross-origin viz refused\n", { status: 403 });
		}
		const { socket, response } = Deno.upgradeWebSocket(req);
		pipeVizSocket(socket, `ws://127.0.0.1:${VIZ_PORT}${endpointPath}${search}`);
		return response;
	};

	// The browser UI lives in ui/: page.html, the rooms stylesheets, and a set of React components
	// entered through main.tsx. page.html and the stylesheets are read fresh on each request, so
	// editing them shows on a browser refresh with no restart. The components are authored in
	// TypeScript and JSX (ui/deno.json targets the DOM libs) and served as code-split JavaScript.
	// A pre-built ui/bundle directory is used if present. The deploy builds it ahead of time
	// with `deno bundle`, so the runtime does not need bundler dependencies. Otherwise the
	// graph is built here. Either way it is rebuilt whenever a module it was
	// built from is newer than it, so a reload shows an edit. Everything is served with
	// no-store, so a browser always fetches the current build.
	const UI_DIR = `${ROOT}ui/`;
	// Every directory the browser bundle draws modules from. A staleness check that
	// misses one serves code from before an edit while the page assets around it are
	// current, which reads as "my change did nothing" and is very hard to see.
	const SOURCE_DIRS = [UI_DIR, `${ROOT}../lib/`, `${ROOT}../../../bindings/ts/`];
	// Not minified, so the served bundle stays readable in the browser's view-source.
	// A production build can shrink it a lot by adding "--minify" to a pre-built
	// bundle directory (see deploy/README.md).
	const BROWSER_BUNDLE_CONFIG = `${ROOT}browser-bundle.json`;
	const WASM_PATH = `${ROOT}../../../zig-out/wasm/pancake_host.wasm`;
	async function bundleClient(): Promise<Map<string, string>> {
		const outdir = await Deno.makeTempDir({ prefix: "pancake-rooms-browser-" });
		try {
			const { code, stderr } = await new Deno.Command("deno", {
				args: [
					"bundle",
					"--platform",
					"browser",
					"--quiet",
					"--code-splitting",
					"--config",
					BROWSER_BUNDLE_CONFIG,
					"--outdir",
					outdir,
					`${UI_DIR}main.tsx`,
				],
				stdout: "null",
				stderr: "piped",
			}).output();
			if (code !== 0) {
				throw new Error(new TextDecoder().decode(stderr).trim() || "deno bundle failed");
			}
			const bundles = new Map<string, string>();
			for await (const entry of Deno.readDir(outdir)) {
				if (entry.isFile && entry.name.endsWith(".js")) {
					bundles.set(entry.name, await Deno.readTextFile(`${outdir}/${entry.name}`));
				}
			}
			if (!bundles.has("main.js")) throw new Error("deno bundle produced no main browser entry");
			return bundles;
		} finally {
			await Deno.remove(outdir, { recursive: true }).catch(() => {});
		}
	}
	// The newest modification time across every module the bundle is built from, or
	// null if none can be read. It walks, rather than reading one directory, so
	// putting a component in a subdirectory cannot quietly stop the staleness check
	// from seeing it.
	async function newestSourceTime(): Promise<number | null> {
		let newest: number | null = null;
		const note = (at: number | undefined) => {
			if (at !== undefined && (newest === null || at > newest)) newest = at;
		};
		const walk = async (dir: string): Promise<void> => {
			try {
				for await (const entry of Deno.readDir(dir)) {
					const path = `${dir}${entry.name}`;
					if (entry.isDirectory) {
						// Installed packages are not what anyone is editing, and
						// walking them costs more than the check is worth.
						if (entry.name !== "node_modules") await walk(`${path}/`);
						continue;
					}
					if (!entry.isFile) continue;
					if (!/\.(tsx?|css|html)$/.test(entry.name)) continue;
					note((await Deno.stat(path)).mtime?.getTime());
				}
			} catch {
				// A directory that cannot be read says nothing about staleness.
			}
		};
		for (const dir of SOURCE_DIRS) await walk(dir);
		return newest;
	}

	/** The bundle being served, and the newest source time it was built from.
	 *
	 * A bundle is stale the moment a module it was built from is newer than it, and
	 * that is one rule whether the bundle came off disk or was built here. It is
	 * the only thing the page loads that could go quietly out of date: page.html,
	 * the rooms stylesheets, and the wasm module are all read fresh per request, so a stale
	 * bundle serves old code inside a page that otherwise reloaded, and the edit
	 * looks like it did nothing. */
	let browserBundles = new Map<string, string>();
	let pageJsAt = 0;
	/** The source time a rebuild already failed on, so a broken edit is reported
	 * once rather than on every page load. Moving a source retries. */
	let failedSourceAt = 0;
	/** The rebuild in flight, so concurrent page loads share one, and the source
	 * time it is building for. A page load that joins a build already running has
	 * to report against that build's source time, not its own. */
	let rebuilding: { at: number; done: Promise<void> } | null = null;

	async function bundleInto(sourceAt: number): Promise<void> {
		browserBundles = await bundleClient();
		pageJsAt = sourceAt;
	}

	/** Bring the bundle up to date if a module it was built from has moved. Returns
	 * the reason a rebuild failed, or null when there was nothing to do or it
	 * worked. A failure leaves the last good build standing: a deployment with no
	 * bundler has one prepared, and a syntax error mid-edit should not take the
	 * page down. */
	async function refreshPageJs(): Promise<string | null> {
		const sourceAt = await newestSourceTime();
		if (sourceAt === null || sourceAt <= pageJsAt || sourceAt === failedSourceAt) return null;
		if (rebuilding === null) rebuilding = { at: sourceAt, done: bundleInto(sourceAt) };
		const attempt = rebuilding;
		try {
			await attempt.done;
			return null;
		} catch (err) {
			// The failure belongs to the source time the build was actually for. A
			// load that joined a build already running would otherwise blame its own
			// newer edit for a build nobody ran on it, and then skip the rebuild that
			// edit is owed.
			failedSourceAt = attempt.at;
			return reasonOf(err);
		} finally {
			if (rebuilding === attempt) rebuilding = null;
		}
	}

	// The deploy path: a bundle prepared ahead of time, so the runtime needs no
	// bundler. `refreshPageJs` holds it to the same staleness rule as one built
	// here, and if there is no bundler to rebuild with, this is what stands.
	try {
		const bundleDir = `${UI_DIR}bundle/`;
		let oldest = Number.POSITIVE_INFINITY;
		for await (const entry of Deno.readDir(bundleDir)) {
			if (!entry.isFile || !entry.name.endsWith(".js")) continue;
			browserBundles.set(entry.name, await Deno.readTextFile(`${bundleDir}${entry.name}`));
			oldest = Math.min(oldest, (await Deno.stat(`${bundleDir}${entry.name}`)).mtime?.getTime() ?? 0);
		}
		if (!browserBundles.has("main.js")) browserBundles.clear();
		else pageJsAt = Number.isFinite(oldest) ? oldest : 0;
	} catch {
		browserBundles.clear();
		pageJsAt = 0;
	}
	// Build at startup rather than on the first page load, so a bundler failure is
	// an error in the terminal the server was started from.
	const startupFailure = await refreshPageJs();
	if (!browserBundles.has("main.js")) {
		console.error(
			`rooms: could not build the browser UI: ${startupFailure ?? "no bundle produced"}`,
		);
		await stop(1);
	}
	if (startupFailure !== null) {
		console.warn(`rooms: could not rebundle (${startupFailure}); serving the prepared browser bundles`);
	}

	// A short human reason from any thrown value.
	function reasonOf(err: unknown): string {
		return err instanceof Error ? err.message : String(err);
	}

	/** A strong validator for one asset body: two independent 32-bit FNV-1a
	 * passes over the text. The pair only has to tell versions of one URL
	 * apart, so a collision needs one exact 64-bit accident between an old
	 * build and its replacement. */
	function contentTag(body: string): string {
		let a = 0x811c9dc5;
		let b = 0x1000193;
		for (let i = 0; i < body.length; i++) {
			const c = body.charCodeAt(i);
			a = Math.imul(a ^ c, 0x01000193);
			b = Math.imul(b ^ c, 0x01000197);
		}
		return `"${(a >>> 0).toString(16)}-${(b >>> 0).toString(16)}"`;
	}

	/** Serve one page asset so a browser never uses a stale copy and never
	 * re-downloads a current one. `no-cache` (not `no-store`) makes every use
	 * revalidate against the tag — the freshness `no-store` bought, at the
	 * price of one round trip instead of the whole body when nothing moved. */
	function asset(req: Request, body: string, type: string): Response {
		const tag = contentTag(body);
		if (req.headers.get("if-none-match")?.split(",").some((held) => held.trim() === tag)) {
			return new Response(null, { status: 304, headers: { etag: tag } });
		}
		return new Response(body, {
			headers: { "content-type": type, "cache-control": "no-cache", etag: tag },
		});
	}

	async function serveIcePolicy(): Promise<Response> {
		try {
			return new Response(JSON.stringify(await ICE_POLICY.servers()), {
				headers: {
					"content-type": "application/json; charset=utf-8",
					"cache-control": "no-store",
				},
			});
		} catch (err) {
			// Never fall back to STUN-only after a deployment configured TURN: that
			// would make restrictive-NAT failures look intermittent and would conceal
			// an unavailable credential authority. The browser loader retries this
			// explicit failure, while the long-lived issuer token remains server-side.
			console.error(`rooms: could not mint TURN credentials: ${reasonOf(err)}`);
			return new Response("rooms: ICE configuration unavailable\n", { status: 503 });
		}
	}
	// The typefaces ui/tokens.css names, by exact filename. Fonts are immutable once
	// published, so unlike the page assets they are cached hard.
	const FONTS = new Set([
		"ibm-plex-sans-latin-wght-normal.woff2",
		"ibm-plex-sans-latin-wght-italic.woff2",
		"ibm-plex-mono-latin-400-normal.woff2",
		"ibm-plex-mono-latin-400-italic.woff2",
		"ibm-plex-mono-latin-600-normal.woff2",
	]);

	async function serveFont(name: string): Promise<Response> {
		if (!FONTS.has(name)) return new Response("not found\n", { status: 404 });
		try {
			return new Response(await Deno.readFile(`${UI_DIR}fonts/${name}`), {
				headers: {
					"content-type": "font/woff2",
					"cache-control": "public, max-age=31536000, immutable",
				},
			});
		} catch (err) {
			return new Response(`rooms: could not read ui/fonts/${name}: ${reasonOf(err)}`, {
				status: 500,
			});
		}
	}

	// Read a UI file fresh for each request, so editing page.html or a stylesheet shows on a
	// browser refresh without restarting this process.
	async function serveUi(req: Request, name: string, type: string): Promise<Response> {
		try {
			return asset(req, await Deno.readTextFile(`${UI_DIR}${name}`), type);
		} catch (err) {
			return new Response(`rooms: could not read ui/${name}: ${reasonOf(err)}`, { status: 500 });
		}
	}

	// ── The byte relay ───────────────────────────────────────────────────────
	// A browser peer speaks OCapN itself but cannot open a socket directly, so this
	// endpoint carries its bytes. A *dial* rides `/relay?target=<locator>`: a
	// `host:port` reaches the room server over TCP, an `ocapn://…iroh` URI reaches a
	// member over iroh (relay.ts dials and pipes without parsing, so the keyed
	// handshake rides through end to end). A *cold-dial* to a browser is a different
	// operation — a bridge, not a dial — so it has its own path: `/relay?rendezvous=
	// <designator>` bridges onto the inbound socket the browser holds by registering
	// at `/register?id=<designator>` (ADR-0088). The allow-list keeps TCP on the room
	// server only; an ocapn:// dial target may name any iroh node, key-verified end
	// to end.
	//
	// A relay session is a persistent, mostly-quiet byte pipe (a chat peer types
	// rarely), so liveness is the WebSocket ping/pong, not a byte-traffic idle
	// timeout that cannot tell a live-but-quiet peer from a dead one (that byte-idle
	// is off in relay.ts, or a quiet peer would be dropped and reconnect every
	// idle window). Deno pings; a live browser auto-pongs and stays connected, and a
	// dead one is reclaimed after this many seconds.
	const RELAY_WS_IDLE_TIMEOUT_S = 120;

	try {
		// The caller prints the serving block once this returns; Deno's own
		// "Listening on …" banner would land in the middle of it in another
		// voice, so it stays quiet.
		Deno.serve({ port: HTTP_PORT, signal: shutdown.signal, onListen: () => {} }, (req) => {
			const url = new URL(req.url);
			// A browser that cannot be dialed registers its keyed identity and a held
			// inbound socket here; a peer redeeming an introduction to it dials
			// `/relay?rendezvous=<designator>` and is bridged onto the held socket
			// (ADR-0088). Byte-transparent like every relay leg.
			if (url.pathname === "/register") {
				const id = url.searchParams.get("id");
				if (!id) {
					return new Response("rooms: register requires ?id=<designator>\n", { status: 400 });
				}
				if (!isRendezvousDesignator(id)) {
					return new Response("rooms: invalid rendezvous designator\n", { status: 400 });
				}
				if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
					return new Response("rooms: cross-origin register refused\n", { status: 403 });
				}
				// A held registration parks idle until a cold-dial bridges it, so it
				// needs its own liveness bound: Deno pings the socket and closes it if
				// no pong lands within `idleTimeout` (ADR-0086's idle reclaim is scoped
				// to a *bridged* pair, not a held idle one). A live browser auto-pongs
				// and stays registered; a peer that died without a clean close (mobile
				// sleep, a dropped network) is reclaimed here, so `Rendezvous.has`
				// never reports a corpse as present and a dialer never bridges a corpse.
				const { socket, response } = Deno.upgradeWebSocket(req, { idleTimeout: 30 });
				registerRendezvous(socket, id);
				return response;
			}
			if (url.pathname === "/relay") {
				// A cold-dial to a browser is a *bridge* to a held socket, not a dial, so
				// it is its own path: `?rendezvous=<designator>` bridges onto the inbound
				// socket that identity holds here (ADR-0088).
				const rendezvousId = url.searchParams.get("rendezvous");
				if (rendezvousId) {
					if (!isRendezvousDesignator(rendezvousId)) {
						return new Response("rooms: invalid rendezvous designator\n", { status: 400 });
					}
					// Not a proxy: the designator is the capability to request a
					// bridge, and native dialers already arrive without Origin.
					// `relayOriginAllowed` would refuse a browser attaching to a
					// tab-hosted session from another page origin (ADR-0134),
					// which the client reports only as `WebSocket connect failed`.
					const { socket, response } = Deno.upgradeWebSocket(req, {
						idleTimeout: RELAY_WS_IDLE_TIMEOUT_S,
					});
					bridgeRendezvous(socket, rendezvousId);
					return response;
				}
				// A dial: `?target=<locator>` — a `host:port` dials TCP, an `ocapn://` URI
				// dials iroh. The shared `classifyRelayTarget` sorts the locator once
				// through the core; the classified target then gates admission and drives
				// the dial. A cold-dial to a browser is a bridge, not a dial, and took the
				// `?rendezvous=` branch above.
				const target = url.searchParams.get("target");
				if (!target) {
					return new Response(
						"rooms: relay requires ?target=<host:port | ocapn:// URI> or ?rendezvous=<id>\n",
						{ status: 400 },
					);
				}
				if (target.length > 2048) {
					return new Response("rooms: relay target too long\n", { status: 400 });
				}
				let classified: RelayTarget;
				try {
					classified = classifyRelayTarget(target);
				} catch {
					return new Response("rooms: unparseable relay target locator\n", { status: 400 });
				}
				if (!relayAllowed(classified, Number(ROOM_PORT), RELAY_TCP_PEERS, onionDesignator(roomLocator()))) {
					return new Response(
						`rooms: relay target not allowed (TCP relay reaches 127.0.0.1:${ROOM_PORT} ` +
							`and the peers named in PANCAKE_RELAY_TCP_PEERS; an onion target must be ` +
							`this room's own service)\n`,
						{ status: 403 },
					);
				}
				if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
					return new Response("rooms: cross-origin relay refused\n", { status: 403 });
				}
				// The admitted onion target is the supervised room itself, and Tor
				// forwards that service to the room port on loopback. Dialing the
				// forward endpoint carries the same bytes a circuit would deliver
				// there, so the tab reaches its own room without a circuit.
				const resolved: RelayTarget = classified.kind === "onion"
					? { kind: "tcp", hostname: "127.0.0.1", port: Number(ROOM_PORT) }
					: classified;
				const { socket, response } = Deno.upgradeWebSocket(req, {
					idleTimeout: RELAY_WS_IDLE_TIMEOUT_S,
				});
				relayToTarget(socket, resolved);
				return response;
			}
			// CapTP peers (rooms-peer) bootstrap the live ocapn:// locator over HTTP
			// on the shared Docker network, then dial via iroh Discovery — not CapTP
			// over this port.
			// What a browser peer needs to find a path to another browser peer.
			// Served rather than built into the page, because the set names hosts
			// this deployment chose to depend on. A process restart applies a new
			// deployment choice without rebuilding the browser bundle.
			if (url.pathname === "/ice") {
				return serveIcePolicy();
			}
			if (url.pathname === "/locator") {
				if (!roomLocator()) {
					return new Response("rooms: locator not ready\n", { status: 503 });
				}
				return new Response(`${roomLocator()}\n`, {
					headers: {
						"content-type": "text/plain; charset=utf-8",
						"cache-control": "no-store",
					},
				});
			}
			// Where a browser member publishes its own trace, so its direct
			// messages appear on the same timeline as the room's own sessions. A
			// WebSocket upgrade here is carried to the timeline endpoint itself,
			// query string and all, so the page reaches it through its own origin:
			// the endpoint's port is container-side and may not be published to
			// the browser's host at all, and an HTTPS page could not open a bare
			// `ws://` port anyway. The endpoint still judges the capability; this
			// leg only moves the socket's bytes. A plain GET answers the port for
			// an operator reading by hand; the page itself never needs it.
			if (url.pathname === "/viz") {
				if (VIZ_PORT === "") {
					// Nothing here, said without making the browser log a failed
					// request on every page load: the page asks this at boot to
					// find out whether there is a timeline to publish to, and a
					// server started without `--viz` is the ordinary answer
					// rather than an error. `advertisedViz` reads the status,
					// so only a 200 names an endpoint.
					return new Response(null, { status: 204 });
				}
				if (VIZ_PORT === "0") {
					// An ephemeral endpoint port is chosen inside the room server
					// and announced on its stderr, which this process passes
					// through rather than reading. Nothing here can name it.
					return new Response(
						"rooms: the live timeline endpoint took an ephemeral port; " +
							"set PANCAKE_ROOMS_VIZ_PORT to a fixed one, or open the page with ?viz=<ws url>\n",
						{ status: 409 },
					);
				}
				if (req.headers.get("upgrade")?.toLowerCase() === "websocket") {
					return carryVizSocket(req, url.search, "/");
				}
				return new Response(`${VIZ_PORT}\n`, {
					headers: {
						"content-type": "text/plain; charset=utf-8",
						"cache-control": "no-store",
					},
				});
			}
			// The producer half of the same origin door: the page's publisher
			// rewrites its endpoint path to `/publish`, so that path is carried
			// to the endpoint's own producer leg the same way.
			if (url.pathname === "/publish" && req.headers.get("upgrade")?.toLowerCase() === "websocket") {
				if (VIZ_PORT === "" || VIZ_PORT === "0") {
					return new Response("rooms: no reachable live timeline endpoint\n", { status: 404 });
				}
				return carryVizSocket(req, url.search, "/publish");
			}
			if (url.pathname === "/page.js") {
				return (async () => {
					const failed = await refreshPageJs();
					if (failed !== null) {
						console.warn(
							`rooms: could not rebuild the browser UI (${failed}); serving the last build`,
						);
					}
					return asset(req, browserBundles.get("main.js") ?? "", "text/javascript; charset=utf-8");
				})();
			}
			const browserChunk = /^\/([A-Za-z0-9_-]+\.js)$/.exec(url.pathname)?.[1];
			if (browserChunk != null && browserBundles.has(browserChunk)) {
				return asset(req, browserBundles.get(browserChunk)!, "text/javascript; charset=utf-8");
			}
			// The browser peer's wasm Host module (ADR-0070), fetched by the page's
			// `@pancake/web` init. Read fresh so a rebuilt module serves without a
			// restart, like the page assets. Its validator is the file's size and
			// write time rather than a content hash, because hashing megabytes on
			// every page load would spend more than the revalidation saves; a
			// rebuilt module moves both.
			if (url.pathname === "/pancake_host.wasm") {
				return (async () => {
					try {
						const stat = await Deno.stat(WASM_PATH);
						const tag = `"${stat.size.toString(16)}-${(stat.mtime?.getTime() ?? 0).toString(16)}"`;
						if (req.headers.get("if-none-match")?.split(",").some((held) => held.trim() === tag)) {
							return new Response(null, { status: 304, headers: { etag: tag } });
						}
						const bytes = await Deno.readFile(WASM_PATH);
						return new Response(bytes, {
							headers: {
								"content-type": "application/wasm",
								"cache-control": "no-cache",
								etag: tag,
							},
						});
					} catch {
						return new Response(
							"rooms: pancake_host.wasm not built (zig build wasm-driver)\n",
							{
								status: 503,
							},
						);
					}
				})();
			}
			if (url.pathname === "/tokens.css") return serveUi(req, "tokens.css", "text/css; charset=utf-8");
			// Rooms stylesheets besides the shared core. Names are an allowlist
			// shape (one path segment, letters and dashes) so a crafted path cannot
			// walk out of ui/.
			if (/^\/[a-z0-9-]+\.css$/.test(url.pathname)) {
				return serveUi(req, url.pathname.slice(1), "text/css; charset=utf-8");
			}
			// The typefaces ui/tokens.css declares. Served from an allowlist rather than
			// by joining the request path onto a directory, so a crafted path cannot
			// walk out of ui/fonts and read the rest of the machine.
			if (url.pathname.startsWith("/fonts/")) {
				return serveFont(url.pathname.slice("/fonts/".length));
			}
			return serveUi(req, "page.html", "text/html; charset=utf-8");
		});
	} catch (err) {
		// The usual cause is a second serve.ts on the same HTTP port; say so and stop the
		// child we just started rather than leave it orphaned.
		console.error(
			`rooms: could not serve on http port ${HTTP_PORT} (${err instanceof Error ? err.message : err}).\n` +
				`       Another rooms web UI may already be on it; try a different port, e.g. serve.ts ${
					HTTP_PORT + 1
				}`,
		);
		await stop(1);
	}
}
