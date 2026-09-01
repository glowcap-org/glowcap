// Connection-independent state for one bridged IRC channel.
//
// Rooms decides who may post and what their name means. This relay retains only
// the already-encoded IRC line needed to finish an admitted post, keeps channel
// membership aligned with Rooms readership, and lends bytes to the current
// connection's serialized writer. A reconnect replaces that writer without
// replacing or re-encoding queued lines.

import { lineCost, MAX_NICK } from "../../lib/limits.ts";
import { encodeIrc, IRC_LINE_BYTES, ircFold, type IrcMessage, nickFromPrefix } from "../protocol.ts";

export const IRC_OUTBOUND_QUEUE_LINES = 64;
export const IRC_OUTBOUND_QUEUE_BYTES = IRC_OUTBOUND_QUEUE_LINES * IRC_LINE_BYTES;
export const IRC_OUTBOUND_INTERVAL_MS = 1_200;
const IRC_JOIN_TIMEOUT_MS = 30_000;

type SendLine = (line: Uint8Array) => Promise<void>;
type Pause = (milliseconds: number) => Promise<void>;
export type IrcSelfEvent = "none" | "self" | "joined" | "left";

interface PendingLine {
	readonly bytes: Uint8Array;
	readonly resolve: () => void;
}

export interface IrcChannelRelayOptions {
	readonly writable?: boolean;
	readonly sendIntervalMs?: number;
	readonly joinTimeoutMs?: number;
	readonly pause?: Pause;
}

/** The bounded queue and join lifecycle shared across IRC reconnects. */
export class IrcChannelRelay {
	readonly channel: string;
	readonly selfNick: string;
	readonly writable: boolean;
	readonly lineBytes: number;
	readonly #sendIntervalMs: number;
	readonly #joinTimeoutMs: number;
	readonly #pause: Pause;
	readonly #pending: PendingLine[] = [];
	#queuedBytes = 0;
	#readers = 0;
	#send: SendLine | null = null;
	#fail: ((error: Error) => void) | null = null;
	#joinTimer: ReturnType<typeof setTimeout> | null = null;
	#joined = false;
	#joining = false;
	#draining = false;
	#generation = 0;

	constructor(channel: string, selfNick: string, options: IrcChannelRelayOptions = {}) {
		this.channel = channel;
		this.selfNick = selfNick;
		this.writable = options.writable ?? false;
		this.#sendIntervalMs = options.sendIntervalMs ?? IRC_OUTBOUND_INTERVAL_MS;
		if (!Number.isSafeInteger(this.#sendIntervalMs) || this.#sendIntervalMs < 0) {
			throw new Error("IRC send interval must be a non-negative integer");
		}
		this.#joinTimeoutMs = options.joinTimeoutMs ?? IRC_JOIN_TIMEOUT_MS;
		if (!Number.isSafeInteger(this.#joinTimeoutMs) || this.#joinTimeoutMs < 1) {
			throw new Error("IRC join timeout must be a positive integer");
		}
		this.#pause = options.pause ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));

		// MAX_NICK is measured in JavaScript code units. One unpaired code unit
		// takes three UTF-8 bytes, which is the largest encoding cost per unit.
		// The advertised Rooms limit is therefore safe for every admitted nick;
		// encodeIrc still checks the exact completed line at admission.
		const fixedBytes = new TextEncoder().encode(`PRIVMSG ${channel} :<> \r\n`).length;
		this.lineBytes = IRC_LINE_BYTES - fixedBytes - MAX_NICK * 3;
		if (this.lineBytes < 1) throw new Error("IRC channel leaves no room for a Rooms message");
	}

	get queuedLines(): number {
		return this.#pending.length;
	}

	get queuedBytes(): number {
		return this.#queuedBytes;
	}

	get joined(): boolean {
		return this.#joined;
	}

	isSelfNick(nick: string): boolean {
		return ircFold(nick) === ircFold(this.selfNick);
	}

	isChannel(channel: string): boolean {
		return this.#isOurChannel(channel);
	}

	/** Retire this channel's membership attempt without condemning a shared
	 * network writer used by sibling channels. */
	refused(error: Error): void {
		const fail = this.#fail;
		this.#retireFailedWriter(this.#generation);
		fail?.(error);
	}

	/** Align IRC membership with the number of live Rooms readers. An admitted
	 * outbound line also keeps the channel joined until that line is written. */
	setReaders(readers: number): void {
		if (!Number.isSafeInteger(readers) || readers < 0) throw new Error("IRC reader count is invalid");
		this.#readers = readers;
		this.#reconcile();
	}

	/** Install the serialized writer for a newly registered IRC connection. */
	connected(send: SendLine, fail: (error: Error) => void): void {
		this.#clearJoinTimer();
		this.#generation += 1;
		this.#send = send;
		this.#fail = fail;
		this.#joined = false;
		this.#joining = false;
		this.#reconcile();
	}

	/** Retire only the connection. Admitted lines remain bounded queue owners and
	 * are retried by the next registered connection. */
	disconnected(): void {
		this.#clearJoinTimer();
		this.#generation += 1;
		this.#send = null;
		this.#fail = null;
		this.#joined = false;
		this.#joining = false;
	}

	/** Observe server-confirmed membership. Returns true for the bridge's own
	 * channel event, which must not appear as an IRC participant in Rooms. */
	observe(message: IrcMessage): IrcSelfEvent {
		const nick = nickFromPrefix(message.prefix);
		const self = nick !== null && this.isSelfNick(nick);
		if (self && message.command === "JOIN" && this.#isOurChannel(message.params[0])) {
			this.#clearJoinTimer();
			this.#joining = false;
			this.#joined = true;
			this.#drain();
			return "joined";
		}
		const kickedSelf = message.command === "KICK" && this.#isOurChannel(message.params[0]) &&
			message.params[1] !== undefined && this.isSelfNick(message.params[1]);
		if (kickedSelf) {
			const fail = this.#fail;
			const generation = this.#generation;
			this.#retireFailedWriter(generation);
			fail?.(new Error(`IRC bridge was kicked from ${this.channel}`));
			return "left";
		}
		if (self && message.command === "PART" && this.#isOurChannel(message.params[0])) {
			// A PART echo may race a freshly queued JOIN. It confirms the older
			// departure and must not cancel the newer join attempt.
			if (this.#joining) return "left";
			this.#clearJoinTimer();
			this.#joining = false;
			this.#joined = false;
			this.#reconcile();
			return "left";
		}
		return self ? "self" : "none";
	}

	/** Admit one Rooms line before returning its delivery promise. Capacity and
	 * the exact IRC line ceiling are checked before any queue state changes. */
	post(nick: string, text: string): Promise<void> {
		if (!this.writable) throw new Error("this IRC bridge is read-only; posting outward has not been granted");
		const textBytes = lineCost(text);
		if (textBytes > this.lineBytes) {
			throw new Error(`a bridged IRC line may be at most ${this.lineBytes} bytes`);
		}
		const bytes = encodeIrc("PRIVMSG", [this.channel, `<${nick}> ${text}`]);
		if (
			this.#pending.length >= IRC_OUTBOUND_QUEUE_LINES ||
			this.#queuedBytes + bytes.length > IRC_OUTBOUND_QUEUE_BYTES
		) {
			throw new Error("the IRC outbound queue is full; retry after earlier lines are delivered");
		}
		const delivered = new Promise<void>((resolve) => {
			this.#pending.push({ bytes, resolve });
		});
		this.#queuedBytes += bytes.length;
		this.#reconcile();
		return delivered;
	}

	#isOurChannel(value: string | undefined): boolean {
		return value !== undefined && ircFold(value) === ircFold(this.channel);
	}

	#wantsChannel(): boolean {
		return this.#readers > 0 || this.#pending.length > 0;
	}

	#reconcile(): void {
		const send = this.#send;
		if (send === null) return;
		if (this.#wantsChannel()) {
			if (!this.#joined && !this.#joining) {
				this.#joining = true;
				const generation = this.#generation;
				void send(encodeIrc("JOIN", [this.channel])).then(() => {
					if (this.#generation !== generation || !this.#joining) return;
					this.#joinTimer = setTimeout(() => {
						if (this.#generation !== generation || !this.#joining) return;
						const fail = this.#fail;
						this.#retireFailedWriter(generation);
						fail?.(new Error(`IRC did not confirm joining ${this.channel}`));
					}, this.#joinTimeoutMs);
				}, () => this.#retireFailedWriter(generation));
			} else if (this.#joined && this.#pending.length > 0) {
				this.#drain();
			}
			return;
		}
		if (this.#joined) {
			this.#joined = false;
			const generation = this.#generation;
			void send(encodeIrc("PART", [this.channel, "no Rooms readers"])).catch(() =>
				this.#retireFailedWriter(generation)
			);
		}
	}

	#retireFailedWriter(generation: number): void {
		if (this.#generation !== generation) return;
		this.#clearJoinTimer();
		this.#generation += 1;
		this.#send = null;
		this.#fail = null;
		this.#joined = false;
		this.#joining = false;
	}

	#clearJoinTimer(): void {
		if (this.#joinTimer === null) return;
		clearTimeout(this.#joinTimer);
		this.#joinTimer = null;
	}

	#drain(): void {
		if (this.#draining || this.#pending.length === 0) return;
		this.#draining = true;
		const generation = this.#generation;
		void (async () => {
			try {
				while (this.#generation === generation && this.#joined && this.#send !== null) {
					const pending = this.#pending[0];
					if (pending === undefined) break;
					try {
						await this.#send(pending.bytes);
					} catch {
						// The connection wrapper closes the failed connection. Retain this
						// exact encoded line for the next registered writer.
						this.#retireFailedWriter(generation);
						break;
					}
					this.#pending.shift();
					this.#queuedBytes -= pending.bytes.length;
					pending.resolve();
					if (this.#pending.length > 0 && this.#sendIntervalMs > 0) {
						await this.#pause(this.#sendIntervalMs);
					}
				}
			} finally {
				this.#draining = false;
				this.#reconcile();
			}
		})().catch(() => {});
	}
}
