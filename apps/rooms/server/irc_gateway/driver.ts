// One reconnecting IRC feed per configured network, with channel projections.

import { connectIrc, type IrcSessionProjection, runIrcSession } from "../../irc/bridge/client.ts";
import type { IrcMessage } from "../../irc/protocol.ts";
import { ircFold } from "../../irc/protocol.ts";
import { IRC_OUTBOUND_INTERVAL_MS, type IrcChannelRelay } from "../../irc/bridge/outbound.ts";
import type { SaslPlainCredentials } from "../../irc/registration.ts";
import type { IrcNetworkChoice } from "../../lib/irc_gateway_client.ts";

type SendLine = (bytes: Uint8Array) => Promise<void>;

function pauseUnlessAborted(milliseconds: number, signal: AbortSignal): Promise<void> {
	if (signal.aborted) return Promise.resolve();
	return new Promise((resolve) => {
		const done = () => {
			clearTimeout(timer);
			signal.removeEventListener("abort", done);
			resolve();
		};
		const timer = setTimeout(done, milliseconds);
		signal.addEventListener("abort", done, { once: true });
	});
}

export interface DrivenIrcBridge {
	readonly roomName: string;
	readonly room: import("../../irc/bridge/room.ts").IrcBridgeRoom;
	status: "connecting" | "up" | "backoff";
	problem: string;
	stopped: boolean;
}

interface Channel {
	readonly held: DrivenIrcBridge;
	readonly relay: IrcChannelRelay;
}

/** Network registration, socket, reconnect policy, and aggregate writer.
 * Channel relays retain their own membership, queue, and room projection. */
export class IrcNetworkFeed implements IrcSessionProjection {
	readonly #channels = new Map<string, Channel>();
	readonly #host: string;
	readonly #port: number;
	readonly #tls: boolean;
	readonly #nick: string;
	readonly #sasl?: SaslPlainCredentials;
	#conn: Deno.Conn | null = null;
	#send: SendLine | null = null;
	#sendTail: Promise<void> = Promise.resolve();
	#sendGeneration = 0;
	readonly #lifetime = new AbortController();
	#stopped = false;
	#started = false;
	#status: "connecting" | "up" | "backoff" = "connecting";
	#problem = "";
	readonly #onTrouble: (source: string, error: unknown) => void;

	constructor(choice: IrcNetworkChoice, onTrouble: (source: string, error: unknown) => void) {
		this.#host = choice.host;
		this.#port = choice.port;
		this.#tls = choice.tls;
		this.#nick = choice.nick;
		this.#sasl = choice.sasl;
		this.#onTrouble = onTrouble;
	}

	get empty(): boolean {
		return this.#channels.size === 0;
	}

	get status(): "connecting" | "up" | "backoff" {
		return this.#status;
	}

	get problem(): string {
		return this.#problem;
	}

	start(): void {
		if (this.#stopped || this.#started) return;
		this.#started = true;
		void this.#drive();
	}

	close(): void {
		if (this.#stopped) return;
		this.#stopped = true;
		this.#lifetime.abort();
		this.#sendGeneration += 1;
		this.#send = null;
		const conn = this.#conn;
		void this.#sendTail.finally(() => {
			try {
				conn?.close();
			} catch { /* already closed */ }
		});
	}

	add(held: DrivenIrcBridge, relay: IrcChannelRelay): void {
		this.#channels.set(ircFold(relay.channel), { held, relay });
		if (this.#send != null) {
			held.status = "up";
			held.problem = "";
			relay.connected(this.#send, (error) => this.#channelFailed(held, error));
		}
	}

	remove(held: DrivenIrcBridge): void {
		const key = ircFold(held.room.channel);
		const channel = this.#channels.get(key);
		if (channel?.held !== held) return;
		this.#channels.delete(key);
		channel.relay.disconnected();
		held.room.disconnected();
	}

	connected(send: SendLine): void {
		this.#status = "up";
		this.#problem = "";
		const generation = ++this.#sendGeneration;
		this.#sendTail = Promise.resolve();
		this.#send = async (bytes) => {
			const prior = this.#sendTail;
			let release!: () => void;
			this.#sendTail = new Promise<void>((resolve) => release = resolve);
			try {
				await prior;
				if (this.#sendGeneration !== generation) throw new Error("the IRC network connection changed");
				await send(bytes);
			} finally {
				if (this.#stopped) release();
				else setTimeout(release, IRC_OUTBOUND_INTERVAL_MS);
			}
		};
		for (const { held, relay } of this.#channels.values()) {
			held.status = "up";
			held.problem = "";
			relay.connected(this.#send, (error) => this.#channelFailed(held, error));
		}
	}

	disconnected(): void {
		this.#sendGeneration += 1;
		this.#sendTail = Promise.resolve();
		this.#send = null;
		for (const { held, relay } of this.#channels.values()) {
			relay.disconnected();
			held.room.disconnected();
		}
	}

	apply(message: IrcMessage): void {
		for (const { held, relay } of this.#channels.values()) {
			const selfEvent = relay.observe(message);
			if (selfEvent === "left") held.room.leftChannel();
			if (selfEvent === "none") held.room.apply(message);
		}
	}

	refusal(message: IrcMessage): Error | null {
		for (const { held, relay } of this.#channels.values()) {
			if (!message.params.some((value) => typeof value === "string" && relay.isChannel(value))) continue;
			const error = new Error(
				`IRC server refused ${held.room.channel}: ${message.params.at(-1) ?? message.command}`,
			);
			relay.refused(error);
			held.room.leftChannel();
			return null;
		}
		return null;
	}

	#channelFailed(held: DrivenIrcBridge, error: Error): void {
		held.status = "backoff";
		held.problem = error.message;
		this.#onTrouble(`the ${held.roomName} IRC channel failed`, error);
	}

	async #drive(): Promise<void> {
		let delay = 1_000;
		while (!this.#stopped) {
			let registeredAt: number | null = null;
			try {
				this.#status = "connecting";
				for (const { held } of this.#channels.values()) held.status = "connecting";
				const conn = await connectIrc({
					hostname: this.#host,
					port: this.#port,
					tls: this.#tls,
					nick: this.#nick,
					signal: this.#lifetime.signal,
				});
				this.#conn = conn;
				if (this.#stopped) {
					conn.close();
					return;
				}
				await runIrcSession(conn, this, {
					nick: this.#nick,
					sasl: this.#sasl,
					onRegistered: () => registeredAt = performance.now(),
				});
			} catch (error) {
				this.#problem = error instanceof Error ? error.message : String(error);
				if (!this.#stopped) this.#onTrouble(`the ${this.#nick} IRC network feed ended`, error);
			} finally {
				this.#conn = null;
				this.disconnected();
			}
			if (this.#stopped) return;
			this.#status = "backoff";
			for (const { held } of this.#channels.values()) held.status = "backoff";
			if (registeredAt != null && performance.now() - registeredAt >= 30_000) delay = 1_000;
			await pauseUnlessAborted(delay, this.#lifetime.signal);
			delay = Math.min(delay * 2, 30_000);
		}
	}
}
