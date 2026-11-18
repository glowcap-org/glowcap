// The page half of the reopen failure capture: a passive record of what one
// document's WebRTC peers and DataChannels did.
//
// `dm_reopen_proof.ts` installs `installPageCapture` before any page script
// runs, in the tabs that advertise a `webrtc` locator. It observes and
// forwards. The native constructor, `createDataChannel` and `send` keep their
// return values, thrown errors, `this` and prototypes, because each is wrapped
// in a Proxy whose `apply`/`construct` trap calls the native one and hands back
// exactly what it returned or threw. Channel events are heard through
// `addEventListener`, registered when the channel first appears, which is before
// the product assigns its `on*` handlers, so a record of an event precedes the
// product's reaction to it. No handler is replaced, delayed, filtered or
// retried.
//
// A send's size is read only from a string or a value the browser itself
// brands as an ArrayBuffer, a view, a DataView or a Blob, through the
// intrinsic getters captured at install. Any other value is reported as an
// unknown size and none of its properties is read, so an argument the native
// overload would never inspect is never inspected here.
//
// A bookkeeping exception is counted in `faults` and never reaches the page.
// The page keeps the most recent `capacity` events: older ones are evicted and
// counted, so a snapshot says how much of the document's history it still has.
// At install the document tells the host its identity through the binding the
// proof exposed. That notification is one call at startup, never an evaluate
// round trip, and a failed call is counted in `faults`.
//
// Stored text is bounded in UTF-16 code units: an event kind or a readiness
// name is at most 40, the document origin at most 120, and an error is a name
// and its first line at most 160. The units are not bytes, so the size of a
// stored event depends on its content and on the engine, and no byte total is
// claimed.
//
// This function is serialized into the page (`Function.prototype.toString`), so
// it names nothing from the module around it.

/** The slice of a page's global scope the observer reads. */
export interface PageScope {
	RTCPeerConnection: PeerConstructor;
	RTCDataChannel: { prototype: ChannelLike };
	performance: { now(): number; timeOrigin: number };
	location?: { origin: string };
	ArrayBuffer: { prototype: object };
	Uint8Array: { prototype: object };
	DataView: { prototype: object };
	Blob?: { prototype: object };
	Math: { random(): number };
	Reflect: typeof Reflect;
	Proxy: ProxyConstructor;
	Object: typeof Object;
}

interface EventTargetLike {
	addEventListener(type: string, listener: (event: EventLike) => void): void;
}

interface EventLike {
	type?: string;
	data?: unknown;
	channel?: ChannelLike;
	error?: { message?: unknown; name?: unknown };
}

/** The members of a native DataChannel the observer reads. */
export interface ChannelLike extends EventTargetLike {
	readyState?: string;
	id?: number | null;
	send(data: unknown): unknown;
}

interface PeerLike extends EventTargetLike {
	signalingState?: string;
	iceConnectionState?: string;
	connectionState?: string;
	createDataChannel(...args: unknown[]): ChannelLike;
}

type PeerConstructor = {
	new (...args: unknown[]): PeerLike;
	prototype: PeerLike;
};

/** One captured page event. `n` is the document-local sequence and `t` the
 * document's own `performance.now()`. */
export interface PageEvent {
	n: number;
	t: number;
	kind: string;
	peer?: number;
	channel?: number;
	origin?: string;
	/** A channel's `readyState`, or for a peer event the state its own event
	 * type names. */
	ready?: string;
	bytes?: number | null;
	sctpId?: number | null;
	error?: string;
}

/** What a page reports about its own capture. */
export interface PageSnapshot {
	installId: string;
	/** `performance.timeOrigin` and `performance.now()` at the snapshot, so a
	 * reader can place the page's clock against the host's on one machine. */
	timeOrigin: number;
	now: number;
	origin: string;
	capacity: number;
	seen: number;
	retained: number;
	evicted: number;
	faults: number;
	peers: number;
	channels: number;
	oldest: { n: number; t: number } | null;
	newest: { n: number; t: number } | null;
	events: PageEvent[];
}

/** What a document tells the host when it installs the observer. */
export interface DocumentInstall {
	installId: string;
	timeOrigin: number;
	origin: string;
}

/** The page global the snapshot is read from. */
export const PAGE_CAPTURE_KEY = "__roomsReopenCapture";
/** The binding the host exposes for the startup notification. */
export const PAGE_CAPTURE_BINDING = "__roomsReopenCaptureInstalled";

/** Install the observer in `scope`. The page's own state is read back through
 * `scope[key].snapshot()`, and the startup notification goes to
 * `scope[binding]` when the host exposed one. */
export function installPageCapture(scope: PageScope, key: string, binding: string, capacity: number): void {
	const { Reflect: R, Proxy: P, Object: O } = scope;
	const TEXT = 40;
	const ERROR_TEXT = 160;
	const events: PageEvent[] = [];
	let seen = 0;
	let evicted = 0;
	let faults = 0;
	let nextPeer = 1;
	let nextChannel = 1;
	const peers = new WeakMap<object, number>();
	const channels = new WeakMap<object, number>();
	const draw = () => Math.floor(scope.Math.random() * 0xffffffff).toString(16);
	const installId = `${draw()}${draw()}`;

	// Every observer call is contained: the page sees native behavior or a
	// native error, never a capture failure.
	const guard = (work: () => void): void => {
		try {
			work();
		} catch {
			faults++; // tolerant: a capture failure is counted in the snapshot, and the page continues untouched.
		}
	};
	const text = (value: unknown, limit: number): string | undefined => {
		return typeof value === "string" ? value.slice(0, limit) : undefined;
	};
	const clip = (error: unknown): string => {
		let label = "unknown";
		try {
			const named = error as { name?: unknown; message?: unknown } | null;
			const name = text(named?.name, TEXT) ?? "error";
			const message = text(named?.message, ERROR_TEXT) ?? "";
			label = `${name}: ${message}`.split("\n")[0].slice(0, ERROR_TEXT);
		} catch {
			faults++; // tolerant: the text is only a label, and the count says it was lost.
		}
		return label;
	};

	// Intrinsic size getters, captured before any page script can replace them.
	// Calling one on a value of another brand throws, which reads as unknown.
	const getter = (proto: object | undefined, name: string): ((this: unknown) => unknown) | null => {
		const descriptor = proto === undefined ? undefined : O.getOwnPropertyDescriptor(proto, name);
		return typeof descriptor?.get === "function" ? descriptor.get : null;
	};
	const sizeGetters = [
		getter(scope.ArrayBuffer.prototype, "byteLength"),
		getter(O.getPrototypeOf(scope.Uint8Array.prototype), "byteLength"),
		getter(scope.DataView.prototype, "byteLength"),
		getter(scope.Blob?.prototype, "size"),
	];
	const utf8Length = (value: string): number => {
		let bytes = 0;
		for (let at = 0; at < value.length; at++) {
			const unit = value.charCodeAt(at);
			if (unit < 0x80) bytes += 1;
			else if (unit < 0x800) bytes += 2;
			else if (
				unit >= 0xd800 && unit < 0xdc00 && at + 1 < value.length &&
				(value.charCodeAt(at + 1) & 0xfc00) === 0xdc00
			) {
				bytes += 4;
				at++;
			} else bytes += 3;
		}
		return bytes;
	};
	const sizeOf = (data: unknown): number | null => {
		try {
			if (typeof data === "string") return utf8Length(data);
			if (data === null || typeof data !== "object") return null;
			for (const read of sizeGetters) {
				if (read === null) continue;
				try {
					const size = read.call(data);
					if (typeof size === "number") return size;
				} catch {
					// A value of another brand: try the next one.
				}
			}
		} catch {
			faults++; // tolerant: an unreadable size is reported as null, and the count says why.
		}
		return null;
	};
	const record = (event: Omit<PageEvent, "n" | "t">): void => {
		guard(() => {
			seen++;
			events.push({ n: seen, t: scope.performance.now(), ...event });
			if (events.length > capacity) {
				events.shift();
				evicted++;
			}
		});
	};
	const readyOf = (channel: ChannelLike): string | undefined => text(channel.readyState, TEXT);
	// Three distinct native state spaces, each recorded under its event type. An
	// absent event says only that none was heard.
	const peerStates = [
		["signalingstatechange", "signalingState"],
		["iceconnectionstatechange", "iceConnectionState"],
		["connectionstatechange", "connectionState"],
	] as const;

	const channelId = (channel: ChannelLike, origin?: string, peer?: number): number => {
		let id = channels.get(channel);
		if (id !== undefined) return id;
		id = nextChannel++;
		channels.set(channel, id);
		record({ kind: "channel", channel: id, peer, origin, ready: readyOf(channel) });
		for (const type of ["open", "message", "close", "error"]) {
			channel.addEventListener(type, (event) => {
				guard(() => {
					if (type === "message") {
						record({ kind: type, channel: id, ready: readyOf(channel), bytes: sizeOf(event.data) });
					} else if (type === "error") {
						record({ kind: type, channel: id, ready: readyOf(channel), error: clip(event.error) });
					} else {
						record({ kind: type, channel: id, ready: readyOf(channel), sctpId: channel.id ?? null });
					}
				});
			});
		}
		return id;
	};

	const peerClass = scope.RTCPeerConnection;
	scope.RTCPeerConnection = new P(peerClass, {
		construct(target, args, newTarget) {
			const peer = R.construct(target, args, newTarget) as PeerLike;
			guard(() => {
				const id = nextPeer++;
				peers.set(peer, id);
				record({ kind: "peer", peer: id });
				peer.addEventListener("datachannel", (event) => {
					guard(() => {
						if (event.channel) channelId(event.channel, "incoming", id);
					});
				});
				for (const [type, stateKey] of peerStates) {
					peer.addEventListener(type, () => {
						guard(() => record({ kind: type, peer: id, ready: text(peer[stateKey], TEXT) }));
					});
				}
			});
			return peer;
		},
	});

	const proto = peerClass.prototype;
	const createChannel = proto.createDataChannel;
	proto.createDataChannel = new P(createChannel, {
		apply(target, self, args) {
			const channel = R.apply(target, self, args) as ChannelLike;
			guard(() => {
				channelId(channel, "outgoing", peers.get(self));
			});
			return channel;
		},
	});

	const channelProto = scope.RTCDataChannel.prototype;
	const send = channelProto.send;
	channelProto.send = new P(send, {
		apply(target, self, args) {
			let id: number | undefined;
			guard(() => {
				id = channelId(self, undefined, undefined);
				record({ kind: "send", channel: id, ready: readyOf(self), bytes: sizeOf(args[0]) });
			});
			try {
				const result = R.apply(target, self, args);
				record({ kind: "sent", channel: id });
				return result;
			} catch (error) {
				record({ kind: "send-threw", channel: id, error: clip(error) });
				throw error;
			}
		},
	});

	const origin = text(scope.location?.origin, TEXT * 3) ?? "";
	O.defineProperty(scope, key, {
		value: {
			snapshot: (): PageSnapshot => ({
				installId,
				timeOrigin: scope.performance.timeOrigin,
				now: scope.performance.now(),
				origin,
				capacity,
				seen,
				retained: events.length,
				evicted,
				faults,
				peers: nextPeer - 1,
				channels: nextChannel - 1,
				oldest: events.length > 0 ? { n: events[0].n, t: events[0].t } : null,
				newest: events.length > 0 ? { n: events[events.length - 1].n, t: events[events.length - 1].t } : null,
				events: events.map((event) => ({ ...event })),
			}),
		},
		enumerable: false,
	});

	// Tell the host which document this is. The call is made once, at install,
	// and its answer is observed so a refusal is counted and never unhandled.
	guard(() => {
		const notify = R.get(scope, binding);
		if (typeof notify !== "function") return;
		const answer: unknown = notify({ installId, timeOrigin: scope.performance.timeOrigin, origin });
		if (
			answer !== null && typeof answer === "object" && typeof (answer as { then?: unknown }).then === "function"
		) {
			(answer as Promise<unknown>).then(undefined, () => {
				faults++; // tolerant: a refused notification is counted in the snapshot.
			});
		}
	});
}
