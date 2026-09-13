// Where a rooms test finds the repository and the installed native executables.
//
// The build names every executable through one shape, `GLOWCAP_ROOMS_<NAME>_BIN`,
// set for each Deno batch and each proof by `tools/build/rooms/tests.zig`. A
// proof run by hand gets the same executables from the install prefix, so the
// fallback is the path `zig build` installs to and nothing else.

/** The repository root, with a trailing slash. */
export const ROOT = new URL("../../../../", import.meta.url).pathname;

/** Where the shared libraries the native executables open are installed. */
export const LIB_DIR = `${ROOT}zig-out/lib`;

function installed(name: string, variable: string): string {
	return Deno.env.get(variable) || `${ROOT}zig-out/bin/${name}`;
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
/** The IRC client front. */
export const IRC_FRONT = installed("rooms-irc-front", "GLOWCAP_ROOMS_IRC_FRONT_BIN");
