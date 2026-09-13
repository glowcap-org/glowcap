// Runs in Chromium. Observe the actual resources constructed by Rust without
// giving the production binding a raw-peer escape hatch or a test-only API.
export async function checkRtcPeers() {
	const binding = await import("/rooms_contract_proofs.js");
	const Original = globalThis.RTCPeerConnection;
	const peers = [];
	const violations = [];
	globalThis.RTCPeerConnection = new Proxy(Original, {
		construct(target, args) {
			const pc = Reflect.construct(target, args);
			const observed = { pc, channels: [], offers: 0 };
			peers.push(observed);
			const channel = (dc) => {
				const entry = { dc, opened: dc.readyState === "open" };
				observed.channels.push(entry);
				dc.addEventListener("open", () => {
					entry.opened = true;
				}, { once: true });
			};
			const createChannel = pc.createDataChannel.bind(pc);
			pc.createDataChannel = (...args) => {
				const dc = createChannel(...args);
				channel(dc);
				return dc;
			};
			pc.addEventListener("datachannel", (event) => channel(event.channel));
			const createOffer = pc.createOffer.bind(pc);
			pc.createOffer = (...args) => {
				observed.offers++;
				return createOffer(...args);
			};
			const close = pc.close.bind(pc);
			pc.close = () => {
				for (const { dc, opened } of observed.channels) {
					if (opened && dc.readyState !== "closed") {
						violations.push("parent closed before established data channel");
					}
				}
				close();
			};
			if (peers.length >= 5) {
				setTimeout(() => {
					Object.defineProperty(pc, "connectionState", { configurable: true, value: "failed" });
					pc.dispatchEvent(new Event("connectionstatechange"));
					delete pc.connectionState;
				}, 0);
			}
			return pc;
		},
	});
	try {
		await binding.rooms_browser_rtc_peer_contract();
		if (peers.length !== 6 || peers[3].offers !== 1) {
			throw new Error("RTC preparation-close scenario did not start createOffer");
		}
		for (const { pc, channels } of peers) {
			if (
				pc.connectionState !== "closed" || pc.onicecandidate !== null || pc.ondatachannel !== null ||
				pc.onconnectionstatechange !== null
			) {
				violations.push("Rust Host retired before peer connection and callbacks");
			}
			for (const { dc } of channels) {
				if (
					dc.readyState !== "closed" || dc.onmessage !== null || dc.onclose !== null || dc.onerror !== null ||
					dc.onopen !== null || dc.onbufferedamountlow !== null
				) {
					violations.push("Rust Host retired before peer data channel and callbacks");
				}
			}
		}
		if (violations.length) throw new Error(violations.join("; "));
	} finally {
		globalThis.RTCPeerConnection = Original;
		for (const { pc } of peers) pc.close();
	}
}
