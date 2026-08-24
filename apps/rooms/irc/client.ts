// The network driver for the IRC bridge. It owns TLS, registration and SASL,
// PING replies, join timing, and reconnectable connection closure; parsed
// channel state is handed to IrcBridgeRoom.

import { IrcBridgeRoom } from "./bridge.ts";
import { readIrcLines } from "./protocol.ts";
import { IrcChannelRelay } from "./outbound.ts";
import { type SaslPlainCredentials, saslPlainPayload, validateIrcNick, validateSaslPlain } from "./registration.ts";
import { IrcSocketWriter } from "./socket_writer.ts";

export interface IrcConnectionOptions {
	readonly nick: string;
	readonly username?: string;
	readonly realname?: string;
	readonly registrationTimeoutMs?: number;
	readonly onRegistered?: () => void;
	readonly sasl?: SaslPlainCredentials;
}

export async function sendSaslPlain(writer: IrcSocketWriter, credentials: SaslPlainCredentials): Promise<void> {
	const payload = saslPlainPayload(credentials);
	for (let offset = 0; offset < payload.length; offset += 400) {
		await writer.send("AUTHENTICATE", [payload.slice(offset, offset + 400)]);
	}
	if (payload.length % 400 === 0) await writer.send("AUTHENTICATE", ["+"]);
}

/** Drive one already-connected IRC session until EOF. Exported so the
 * hermetic fixture proves the same registration and PING path production uses. */
export async function runIrcSession(
	conn: Deno.Conn,
	room: IrcBridgeRoom,
	relay: IrcChannelRelay,
	options: IrcConnectionOptions,
): Promise<void> {
	validateIrcNick(options.nick);
	if (options.sasl !== undefined) validateSaslPlain(options.sasl);
	let writeFailure: unknown = null;
	const writer = new IrcSocketWriter(conn, (error) => {
		writeFailure ??= error;
		try {
			conn.close();
		} catch { /* the peer closed first */ }
	});
	if (options.sasl !== undefined) await writer.send("CAP", ["LS", "302"]);
	await writer.send("NICK", [options.nick]);
	await writer.send("USER", [
		options.username ?? options.nick,
		"0",
		"*",
		options.realname ?? "pancake rooms bridge",
	]);
	let registered = false;
	let saslAdvertised = false;
	let saslPlainAdvertised = false;
	let saslRequested = false;
	let saslStarted = false;
	let saslPayloadSent = false;
	let saslAuthenticated = options.sasl === undefined;
	let timedOut = false;
	const registrationTimer = setTimeout(() => {
		timedOut = true;
		try {
			conn.close();
		} catch { /* the peer closed first */ }
	}, options.registrationTimeoutMs ?? 30_000);
	let readFailure: unknown = null;
	const closeForWriteFailure = async (bytes: Uint8Array): Promise<void> => {
		try {
			await writer.write(bytes);
		} catch (error) {
			writeFailure ??= error;
			try {
				conn.close();
			} catch { /* the peer closed first */ }
			throw error;
		}
	};
	try {
		for await (const message of readIrcLines(conn.readable)) {
			if (message.command === "PING") {
				await writer.send("PONG", message.params);
				continue;
			}
			if (message.command === "CAP" && options.sasl !== undefined) {
				const subcommand = message.params[1]?.toUpperCase();
				const capabilities = message.params.at(-1)?.split(/\s+/) ?? [];
				if (subcommand === "LS") {
					for (const capability of capabilities) {
						const [name, mechanisms] = capability.split("=", 2);
						if (name !== "sasl") continue;
						saslAdvertised = true;
						saslPlainAdvertised ||= mechanisms === undefined ||
							mechanisms.split(",").some((mechanism) => mechanism.toUpperCase() === "PLAIN");
					}
					const continued = message.params[2] === "*";
					if (!continued) {
						if (!saslAdvertised) throw new Error("IRC server does not advertise SASL");
						if (!saslPlainAdvertised) {
							throw new Error("IRC server does not advertise the SASL PLAIN mechanism");
						}
						saslRequested = true;
						await writer.send("CAP", ["REQ", "sasl"]);
					}
					continue;
				}
				if (
					subcommand === "ACK" && capabilities.some((capability) => capability.split("=")[0] === "sasl") &&
					saslRequested
				) {
					saslStarted = true;
					await writer.send("AUTHENTICATE", ["PLAIN"]);
					continue;
				}
				if (subcommand === "NAK") throw new Error("IRC server refused the SASL capability");
			}
			if (message.command === "AUTHENTICATE" && options.sasl !== undefined && message.params[0] === "+") {
				if (!saslStarted) throw new Error("IRC server started SASL before agreeing to it");
				if (saslPayloadSent) throw new Error("IRC server requested the SASL payload twice");
				await sendSaslPlain(writer, options.sasl);
				saslPayloadSent = true;
				continue;
			}
			if (message.command === "AUTHENTICATE" && message.params[0] === "*") {
				throw new Error("IRC server aborted SASL authentication");
			}
			if (message.command === "903" && options.sasl !== undefined) {
				if (!saslPayloadSent) throw new Error("IRC server completed SASL before receiving credentials");
				saslAuthenticated = true;
				await writer.send("CAP", ["END"]);
				continue;
			}
			if (["902", "904", "905", "906", "907"].includes(message.command)) {
				throw new Error(`IRC SASL authentication failed (${message.command})`);
			}
			if (message.command === "001" && !registered) {
				if (!saslAuthenticated) throw new Error("IRC registered before SASL authentication completed");
				registered = true;
				clearTimeout(registrationTimer);
				options.onRegistered?.();
				relay.connected(closeForWriteFailure, (error) => {
					writeFailure ??= error;
					try {
						conn.close();
					} catch { /* the peer closed first */ }
				});
				continue;
			}
			if (message.command === "433") throw new Error(`IRC nickname "${options.nick}" is already in use`);
			if (message.command === "005") {
				const mapping = message.params.find((param) => param.toUpperCase().startsWith("CASEMAPPING="));
				if (mapping !== undefined && mapping.slice(mapping.indexOf("=") + 1).toLowerCase() !== "rfc1459") {
					throw new Error(`IRC server uses unsupported ${mapping}`);
				}
			}
			if (["403", "405", "471", "473", "474", "475", "476", "477"].includes(message.command)) {
				throw new Error(`IRC server refused ${room.channel}: ${message.params.at(-1) ?? message.command}`);
			}
			if (message.command === "ERROR") {
				throw new Error(`IRC server closed: ${message.params.at(-1) ?? "unknown reason"}`);
			}
			if (!registered) continue;
			const selfEvent = relay.observe(message);
			if (selfEvent === "left") room.leftChannel();
			if (selfEvent !== "none") continue;
			room.apply(message);
		}
	} catch (error) {
		readFailure = error;
	} finally {
		clearTimeout(registrationTimer);
		relay.disconnected();
		room.disconnected();
	}
	if (timedOut) throw new Error("IRC registration timed out");
	if (writeFailure !== null) throw writeFailure;
	if (readFailure !== null) throw readFailure;
	throw new Error("IRC server ended the connection");
}

export interface IrcEndpoint extends IrcConnectionOptions {
	readonly hostname: string;
	readonly port: number;
	readonly tls: boolean;
}

export async function connectIrc(endpoint: IrcEndpoint): Promise<Deno.Conn> {
	return endpoint.tls
		? await Deno.connectTls({ hostname: endpoint.hostname, port: endpoint.port })
		: await Deno.connect({ hostname: endpoint.hostname, port: endpoint.port });
}
