// The installed native server used by process and browser scenarios.
export const SERVER = Deno.env.get("GLOWCAP_ROOMS_SERVER_BIN") ||
	new URL("../../../../zig-out/bin/rooms-server", import.meta.url).pathname;
