// DENO-SPECIFIC: reading optional configuration from the environment.
//
// Every rooms process honors a handful of optional env vars, and each reads
// them the same way: only when env access is granted, so the default
// permission set never trips, and with empty and unset as one answer.

/** Read an optional env var when permission is granted; otherwise undefined. */
export function optionalEnv(name: string): string | undefined {
	const allowed = Deno.permissions.querySync({ name: "env", variable: name }).state ===
		"granted";
	if (!allowed) return undefined;
	const value = Deno.env.get(name)?.trim();
	return value && value.length > 0 ? value : undefined;
}

/** Whether an operation capability is asked for: its argv flag, or the flag's
 * env twin set to `1`. Every enabling knob (`--diagnostics`,
 * `--admin-listeners`, `--viz`) reads through here so the server and its
 * supervisor cannot answer the same flag differently. */
export function flagOrEnv(args: readonly string[], flag: string, env: string): boolean {
	return args.includes(flag) || optionalEnv(env) === "1";
}

/** The wires a room server can boot on. */
export const ROOM_TRANSPORTS = ["tcp", "iroh", "onion"] as const;
export type RoomTransport = (typeof ROOM_TRANSPORTS)[number];

/** Resolve the transport choice (`--transport=…`, or its
 * `PANCAKE_ROOMS_TRANSPORT` env twin, or the tcp default), or throw naming
 * the whole set. One grammar for the server and its supervisor. */
export function transportChoice(named: string | undefined): RoomTransport {
	const choice = named ?? optionalEnv("PANCAKE_ROOMS_TRANSPORT") ?? "tcp";
	const known = ROOM_TRANSPORTS.find((transport) => transport === choice);
	if (known === undefined) {
		throw new Error(`unknown transport "${choice}" (expected ${ROOM_TRANSPORTS.join(", ")})`);
	}
	return known;
}

/** The port the live timeline endpoint binds while `--viz` is on. The default
 * is the canonical container-side trace port the devcontainer maps out
 * (`.devcontainer/.env.example` pairs it with `PANCAKE_ROOMS_TRACE_HOST_PORT`).
 * `PANCAKE_ROOMS_VIZ_PORT` changes only this default — setting it enables
 * nothing — and `0` asks for an ephemeral port. */
const VIZ_DEFAULT_PORT = "9300";

/** Resolve the viz port choice, or throw when the override is not a port. */
export function vizPortChoice(): string {
	const raw = optionalEnv("PANCAKE_ROOMS_VIZ_PORT");
	if (raw === undefined) return VIZ_DEFAULT_PORT;
	const port = Number(raw);
	if (!Number.isInteger(port) || port < 0 || port > 65535) {
		throw new Error(`PANCAKE_ROOMS_VIZ_PORT is not a port: "${raw}"`);
	}
	return raw;
}
