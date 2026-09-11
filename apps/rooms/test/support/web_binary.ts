// The installed native HTTP front used by process and browser scenarios.
export const WEB = Deno.env.get("GLOWCAP_ROOMS_WEB_BIN") ||
	new URL("../../../../zig-out/bin/rooms-web", import.meta.url).pathname;
