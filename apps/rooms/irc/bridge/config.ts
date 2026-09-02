// Pure command-line configuration for the IRC bridge. Secret lookup is
// injected so tests can prove that two-way mode never accepts a password in
// argv and never enables SASL PLAIN over a clear connection.

import { type SaslPlainCredentials, validateIrcNick, validateSaslPlain } from "../registration.ts";

export const IRC_BRIDGE_USAGE =
	"usage: zig build rooms-irc-bridge -- --network=libera --channel=#ocapn --irc-host=irc.libera.chat --irc-port=6697 --irc-nick=glowcap-rooms --mode=read-only|two-way --sasl-account=ACCOUNT --bind=127.0.0.1 --announce-host=HOST --port=0 --tls=true";

export interface IrcBridgeConfig {
	readonly network: string;
	readonly channel: string;
	readonly ircHost: string;
	readonly ircPort: number;
	readonly ircNick: string;
	readonly mode: "read-only" | "two-way";
	readonly bind: string;
	readonly announceHost?: string;
	readonly port: number;
	readonly tls: boolean;
	readonly sasl?: SaslPlainCredentials;
}

const optionNames = new Set([
	"network",
	"channel",
	"irc-host",
	"irc-port",
	"irc-nick",
	"mode",
	"sasl-account",
	"bind",
	"announce-host",
	"port",
	"tls",
]);

export function parseIrcBridgeConfig(
	args: readonly string[],
	getenv: (name: string) => string | undefined,
): IrcBridgeConfig {
	const supplied = new Map<string, string>();
	for (const arg of args) {
		const match = /^--([^=]+)=(.*)$/.exec(arg);
		if (match === null || !optionNames.has(match[1])) throw new Error(`unknown IRC bridge option: ${arg}`);
		if (supplied.has(match[1])) throw new Error(`IRC bridge option appears twice: --${match[1]}`);
		supplied.set(match[1], match[2]);
	}
	const option = (name: string, fallback: string): string => supplied.get(name) ?? fallback;
	const network = option("network", "libera");
	const channel = option("channel", "#ocapn");
	const ircHost = option("irc-host", "irc.libera.chat");
	const ircPort = portOption("irc-port", option("irc-port", "6697"), false);
	const ircNick = option("irc-nick", "glowcap-rooms");
	const mode = option("mode", "read-only");
	if (mode !== "read-only" && mode !== "two-way") throw new Error("--mode must be read-only or two-way");
	const bind = option("bind", "127.0.0.1");
	const announceHost = supplied.get("announce-host");
	const port = portOption("port", option("port", "0"), true);
	const tlsOption = option("tls", "true");
	if (tlsOption !== "true" && tlsOption !== "false") throw new Error("--tls must be true or false");
	const tls = tlsOption === "true";
	validateIrcNick(ircNick);

	let sasl: SaslPlainCredentials | undefined;
	if (mode === "two-way") {
		if (!tls) throw new Error("two-way IRC requires TLS so SASL PLAIN credentials are not exposed");
		const account = supplied.get("sasl-account");
		if (account === undefined) throw new Error("two-way IRC requires --sasl-account=ACCOUNT");
		const password = getenv("GLOWCAP_ROOMS_IRC_SASL_PASSWORD");
		if (password === undefined) throw new Error("two-way IRC requires GLOWCAP_ROOMS_IRC_SASL_PASSWORD");
		sasl = { account, password };
		validateSaslPlain(sasl);
	} else if (supplied.has("sasl-account")) {
		throw new Error("--sasl-account requires --mode=two-way");
	}

	return { network, channel, ircHost, ircPort, ircNick, mode, bind, announceHost, port, tls, sasl };
}

function portOption(name: string, value: string, allowZero: boolean): number {
	if (!/^[0-9]+$/.test(value)) throw new Error(`--${name} must be a decimal port`);
	const parsed = Number(value);
	if (!Number.isSafeInteger(parsed) || parsed > 65535 || parsed < (allowZero ? 0 : 1)) {
		throw new Error(`--${name} must be ${allowZero ? "0..65535" : "1..65535"}`);
	}
	return parsed;
}
