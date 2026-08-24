// Pure command-line configuration for the IRC client front. The listener is
// loopback-cleartext by default; exposing it beyond loopback requires a TLS
// certificate and key together. Files are read only by front_main.ts.

export const IRC_FRONT_USAGE =
	"usage: zig build rooms-irc-front -- --directory=127.0.0.1:9099 --bind=127.0.0.1 --port=6667 --server-name=rooms.local --tls-cert=PATH --tls-key=PATH --dm-transport=noise|tcp|iroh --dm-bind=127.0.0.1 --dm-announce-host=HOST --dm-port=0";

export type IrcFrontDmConfig =
	| {
		readonly transport: "noise" | "tcp";
		readonly bind: string;
		readonly announceHost?: string;
		readonly port: number;
	}
	| { readonly transport: "iroh" };

export interface IrcFrontConfig {
	readonly directory: string;
	readonly bind: string;
	readonly port: number;
	readonly serverName: string;
	readonly tls?: { readonly certPath: string; readonly keyPath: string };
	readonly dm: IrcFrontDmConfig;
}

const optionNames = new Set([
	"directory",
	"bind",
	"port",
	"server-name",
	"tls-cert",
	"tls-key",
	"dm-transport",
	"dm-bind",
	"dm-announce-host",
	"dm-port",
]);

export function parseIrcFrontConfig(args: readonly string[]): IrcFrontConfig {
	const supplied = new Map<string, string>();
	for (const arg of args) {
		const match = /^--([^=]+)=(.*)$/.exec(arg);
		if (match === null || !optionNames.has(match[1])) throw new Error(`unknown IRC front option: ${arg}`);
		if (supplied.has(match[1])) throw new Error(`IRC front option appears twice: --${match[1]}`);
		supplied.set(match[1], match[2]);
	}
	const option = (name: string, fallback: string): string => supplied.get(name) ?? fallback;
	const directory = option("directory", "127.0.0.1:9099");
	if (directory.length === 0 || /[\0\r\n]/.test(directory)) throw new Error("--directory must name a Rooms locator");
	const bind = option("bind", "127.0.0.1");
	const port = portOption("port", option("port", "6667"));
	const serverName = option("server-name", "rooms.local");
	if (!/^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$/.test(serverName)) {
		throw new Error("--server-name must be a 1..63 character IRC server name");
	}
	const certPath = supplied.get("tls-cert");
	const keyPath = supplied.get("tls-key");
	if ((certPath === undefined) !== (keyPath === undefined)) {
		throw new Error("--tls-cert and --tls-key must be supplied together");
	}
	if (!isLoopback(bind) && certPath === undefined) {
		throw new Error("a non-loopback IRC bind requires --tls-cert and --tls-key");
	}
	const dmTransport = option("dm-transport", "noise");
	if (dmTransport !== "noise" && dmTransport !== "tcp" && dmTransport !== "iroh") {
		throw new Error("--dm-transport must be noise, tcp, or iroh");
	}
	let dm: IrcFrontDmConfig;
	if (dmTransport === "iroh") {
		for (const name of ["dm-bind", "dm-announce-host", "dm-port"]) {
			if (supplied.has(name)) throw new Error(`--${name} does not apply to --dm-transport=iroh`);
		}
		dm = { transport: "iroh" };
	} else {
		const dmBind = option("dm-bind", "127.0.0.1");
		const dmAnnounceHost = supplied.get("dm-announce-host");
		if (isWildcard(dmBind) && dmAnnounceHost === undefined) {
			throw new Error("a wildcard direct-message bind requires --dm-announce-host");
		}
		if (
			dmTransport === "tcp" &&
			(!isLoopback(dmBind) || (dmAnnounceHost !== undefined && !isLoopback(dmAnnounceHost)))
		) {
			throw new Error("the cleartext direct-message transport is restricted to loopback; use noise or iroh");
		}
		dm = {
			transport: dmTransport,
			bind: dmBind,
			...(dmAnnounceHost === undefined ? {} : { announceHost: dmAnnounceHost }),
			port: portOption("dm-port", option("dm-port", "0")),
		};
	}
	return {
		directory,
		bind,
		port,
		serverName,
		...(certPath === undefined ? {} : { tls: { certPath, keyPath: keyPath! } }),
		dm,
	};
}

function portOption(name: string, value: string): number {
	if (!/^[0-9]+$/.test(value)) throw new Error(`--${name} must be a decimal port`);
	const parsed = Number(value);
	if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > 65535) {
		throw new Error(`--${name} must be 0..65535`);
	}
	return parsed;
}

function bareHost(host: string): string {
	return host.startsWith("[") && host.endsWith("]") ? host.slice(1, -1) : host;
}

function isLoopback(host: string): boolean {
	const bare = bareHost(host).toLowerCase();
	if (bare === "localhost" || bare === "::1") return true;
	const match = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(bare);
	return match !== null && Number(match[1]) === 127 && match.slice(1).every((part) => Number(part) <= 255);
}

function isWildcard(host: string): boolean {
	const bare = bareHost(host).toLowerCase();
	return bare === "0.0.0.0" || bare === "::" || /^(?:0*:){2,7}0*$/.test(bare);
}
