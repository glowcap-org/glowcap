// Where a rooms test finds the repository and the installed executables.
//
// The build names every executable through one shape, `GLOWCAP_ROOMS_<NAME>_BIN`,
// set for each Deno batch by `tools/build/rooms/tests.zig` and for each browser
// proof by `tools/build/rooms.zig`. A proof run
// by hand gets the same executables from the install prefix, so the fallback
// is `zig-out/libexec`, where `zig build` installs these private runtimes.

/** The repository root, with a trailing slash. */
export const ROOT = new URL("../../../../", import.meta.url).pathname;

/** Where the shared libraries the installed executables open are installed. */
export const LIB_DIR = `${ROOT}zig-out/lib`;

function installed(name: string, variable: string): string {
	return Deno.env.get(variable) || `${ROOT}zig-out/libexec/${name}`;
}

/** The room server: the directory members register with and the rooms they enter. */
export const SERVER = installed("rooms-server", "GLOWCAP_ROOMS_SERVER_BIN");
/** The HTTP front that serves the page and supervises a room server. */
export const WEB = installed("rooms-web", "GLOWCAP_ROOMS_WEB_BIN");
/** The durable archive peer. */
export const ARCHIVE = installed("rooms-archive", "GLOWCAP_ROOMS_ARCHIVE_BIN");
/** The durable session peer. */
export const SESSION = installed("rooms-session", "GLOWCAP_ROOMS_SESSION_BIN");
/** The standalone IRC bridge. */
export const IRC_BRIDGE = installed("rooms-irc-bridge", "GLOWCAP_ROOMS_IRC_BRIDGE_BIN");
/** The Rooms IRC server. */
export const IRC_SERVER = installed("rooms-irc-server", "GLOWCAP_ROOMS_IRC_SERVER_BIN");
