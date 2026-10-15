/// <reference lib="dom" />

// A stand-in for the browser's RTCPeerConnection, installed on `globalThis`
// for one test and restored after it. A remote description stays pending
// until `finishRemoteDescription`, so a test can hold an exchange mid-flight.

export interface FakePeerConnection {
	readonly calls: string[];
	readonly configuration: RTCConfiguration;
	finishRemoteDescription(): void;
	emitDataChannel(channel: RTCDataChannel): void;
	failConnection(): void;
	emitLocalCandidate(candidate: string): void;
}

export function installFakePeerConnection(
	addCandidate: (candidate: RTCIceCandidateInit) => Promise<void>,
	description: { offerSdp?: string; answerSdp?: string } = {},
): { instance: () => FakePeerConnection; instances: () => readonly FakePeerConnection[]; restore: () => void } {
	const original = Object.getOwnPropertyDescriptor(globalThis, "RTCPeerConnection");
	let current: FakePeerConnection | null = null;
	const made: FakePeerConnection[] = [];

	class FakeRTCPeerConnection {
		onicecandidate: ((event: RTCPeerConnectionIceEvent) => void) | null = null;
		ondatachannel: ((event: RTCDataChannelEvent) => void) | null = null;
		onconnectionstatechange: (() => void) | null = null;
		connectionState: RTCPeerConnectionState = "new";
		readonly calls: string[] = [];
		readonly configuration: RTCConfiguration;
		#resolveRemote!: () => void;
		readonly #remoteInstalled = new Promise<void>((resolve) => {
			this.#resolveRemote = resolve;
		});

		constructor(configuration: RTCConfiguration = {}) {
			this.configuration = configuration;
			current = this;
			made.push(this);
		}

		async setRemoteDescription(): Promise<void> {
			this.calls.push("set remote");
			await this.#remoteInstalled;
		}

		createOffer(): Promise<RTCSessionDescriptionInit> {
			this.calls.push("create offer");
			return Promise.resolve({ type: "offer", sdp: description.offerSdp ?? "offer" });
		}

		createAnswer(): Promise<RTCSessionDescriptionInit> {
			this.calls.push("create answer");
			return Promise.resolve({ type: "answer", sdp: description.answerSdp ?? "answer" });
		}

		setLocalDescription(local: RTCSessionDescriptionInit): Promise<void> {
			this.calls.push(`set local ${local.type}`);
			return Promise.resolve();
		}

		createDataChannel(label: string, options: RTCDataChannelInit = {}): RTCDataChannel {
			return fakeChannel({
				label,
				ordered: options.ordered ?? true,
				maxPacketLifeTime: options.maxPacketLifeTime ?? null,
				maxRetransmits: options.maxRetransmits ?? null,
			});
		}

		async addIceCandidate(candidate: RTCIceCandidateInit): Promise<void> {
			this.calls.push(`candidate ${candidate.candidate}`);
			await addCandidate(candidate);
		}

		finishRemoteDescription(): void {
			this.#resolveRemote();
		}

		emitDataChannel(channel: RTCDataChannel): void {
			this.ondatachannel?.({ channel } as RTCDataChannelEvent);
		}

		emitLocalCandidate(candidate: string): void {
			const init = { candidate, sdpMid: "0", sdpMLineIndex: 0 };
			this.onicecandidate?.({ candidate: { toJSON: () => init } } as unknown as RTCPeerConnectionIceEvent);
		}

		failConnection(): void {
			this.connectionState = "failed";
			this.onconnectionstatechange?.();
		}

		close(): void {}
	}

	Object.defineProperty(globalThis, "RTCPeerConnection", {
		configurable: true,
		writable: true,
		value: FakeRTCPeerConnection as unknown as typeof RTCPeerConnection,
	});
	return {
		instance: () =>
			current ?? (() => {
				throw new Error("fake peer connection was not constructed");
			})(),
		instances: () => made,
		restore: () => {
			if (original) Object.defineProperty(globalThis, "RTCPeerConnection", original);
			else delete (globalThis as { RTCPeerConnection?: unknown }).RTCPeerConnection;
		},
	};
}

export function fakeChannel(
	options: {
		label?: string;
		ordered?: boolean;
		maxPacketLifeTime?: number | null;
		maxRetransmits?: number | null;
	} = {},
): RTCDataChannel {
	return {
		label: options.label ?? "ocapn",
		ordered: options.ordered ?? true,
		maxPacketLifeTime: options.maxPacketLifeTime ?? null,
		maxRetransmits: options.maxRetransmits ?? null,
		readyState: "connecting",
		addEventListener() {},
		close() {},
	} as unknown as RTCDataChannel;
}
