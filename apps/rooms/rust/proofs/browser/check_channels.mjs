import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

import { checkRtcPeers } from "./check_rtc_peers.mjs";
import { snippet } from "./assets.mjs";

const repository = new URL("../../../../../", import.meta.url);
const local = (path) => fileURLToPath(new URL(path, repository));

async function evaluate(page, action, argument) {
	let timer;
	try {
		return await Promise.race([
			page.evaluate(action, argument),
			new Promise((_, reject) => {
				timer = setTimeout(() => reject(new Error("browser channel scenario timed out")), 15_000);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
}

async function readyBase(stdout) {
	const decoder = new TextDecoder();
	let pending = "";
	let address;
	for await (const chunk of stdout) {
		pending += decoder.decode(chunk, { stream: true });
		let newline;
		while ((newline = pending.indexOf("\n")) >= 0) {
			const line = pending.slice(0, newline).trim();
			pending = pending.slice(newline + 1);
			const match = /^web ui\s+http:\/\/localhost:(\d+)$/.exec(line);
			if (match) address = `http://127.0.0.1:${match[1]}`;
			if (line === "rooms: ready") {
				assert(address);
				return address;
			}
		}
	}
	throw new Error("rooms-web exited before readiness");
}

// Exercise the executable users start: it supervises the native directory and
// relays this Wasm client's WebSocket bytes. Deno drives the proof but carries
// no application traffic.
export async function checkChannels(page, { script, wasm, root }, transport = "tcp") {
	const environment = Object.fromEntries(
		Object.entries(Deno.env.toObject()).filter(([key]) =>
			!key.startsWith("GLOWCAP_ROOMS_") && !key.startsWith("GLOWCAP_RELAY_") && key !== "LD_LIBRARY_PATH" &&
			key !== "DYLD_LIBRARY_PATH"
		),
	);
	// Controlled same-host RTC needs no external STUN or TURN service. This also
	// exercises the deployment's explicit empty ICE configuration through Rust.
	environment.GLOWCAP_ROOMS_ICE_SERVERS = "";
	const child = new Deno.Command(Deno.env.get("GLOWCAP_ROOMS_WEB_TEST_BIN") ?? local("zig-out/libexec/rooms-web"), {
		args: [
			"0",
			"0",
			`--transport=${transport}`,
			"--reachability=direct",
			`--assets=${local("apps/rooms/web")}`,
			`--server=${Deno.env.get("GLOWCAP_ROOMS_SERVER_TEST_BIN") ?? local("zig-out/libexec/rooms-server")}`,
		],
		clearEnv: true,
		env: environment,
		stdin: "null",
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
	const exited = child.status;
	let timer;
	try {
		const base = await Promise.race([
			readyBase(child.stdout),
			new Promise((_, reject) => {
				timer = setTimeout(() => reject(new Error("native web startup timed out")), 15_000);
			}),
		]);
		clearTimeout(timer);
		const response = await fetch(`${base}/locator`);
		assert(response.ok);
		const location = (await response.text()).trim();
		const url = `${base.replace(/^http/, "ws")}/relay?target=${encodeURIComponent(location)}`;
		await evaluate(page, async ({ url, location }) => {
			const binding = await import("/rooms_contract_proofs.js");
			const socket = new WebSocket(url);
			try {
				await binding.rooms_browser_websocket_refusal(socket, location);
				if (
					socket.onmessage !== null || socket.onclose !== null || socket.onerror !== null ||
					socket.onopen !== null
				) {
					throw new Error("rejected WebSocket retained Rust callbacks");
				}
			} finally {
				socket.close();
			}
		}, { url, location });
		// Use the native application's origin, preserving its relay origin
		// enforcement. Load a real response so Chromium records its loopback
		// address space; a synthetic document loses that network provenance.
		await page.route(
			`${base}/rooms_contract_proofs.js`,
			(route) => route.fulfill({ contentType: "text/javascript", body: script }),
		);
		await page.route(
			`${base}/rooms_contract_proofs_bg.wasm`,
			(route) => route.fulfill({ contentType: "application/wasm", body: wasm }),
		);
		await page.route(`${base}/snippets/**`, async (route) => {
			const path = new URL(route.request().url()).pathname;
			await route.fulfill({ contentType: "text/javascript", body: await snippet(root, path) });
		});
		await page.goto(`${base}/locator`);
		await evaluate(page, runtimeContract, { location });
		if (transport !== "tcp") return;
		await evaluate(page, relayContract, { base });
		await evaluate(page, checkRtcPeers);
		await evaluate(page, async ({ url, location }) => {
			const binding = await import("/rooms_contract_proofs.js");
			await binding.rooms_browser_signaling_contract(url, location);
			await binding.rooms_browser_signaling_cancel_contract(url, location);
		}, { url, location });
		await evaluate(page, async () => {
			const binding = await import("/rooms_contract_proofs.js");
			const first = new RTCPeerConnection({ iceServers: [] });
			const second = new RTCPeerConnection({ iceServers: [] });
			try {
				const left = first.createDataChannel("captp");
				const received = new Promise((resolve) => {
					second.ondatachannel = (event) => resolve(event.channel);
				});
				// Gather into the SDP before exchange: no detached candidate tasks
				// or swallowed addIceCandidate errors in the controlled local peer.
				const gather = async (peer) => {
					if (peer.iceGatheringState === "complete") return;
					await new Promise((resolve) => {
						peer.onicegatheringstatechange = () => {
							if (peer.iceGatheringState === "complete") {
								peer.onicegatheringstatechange = null;
								resolve();
							}
						};
					});
				};
				await first.setLocalDescription(await first.createOffer());
				await gather(first);
				await second.setRemoteDescription(first.localDescription);
				await second.setLocalDescription(await second.createAnswer());
				await gather(second);
				await first.setRemoteDescription(second.localDescription);
				const right = await received;
				await binding.rooms_browser_rtc_contract(left, right);
				for (const channel of [left, right]) {
					if (
						channel.readyState !== "closed" || channel.onmessage !== null || channel.onclose !== null ||
						channel.onerror !== null || channel.onopen !== null || channel.onbufferedamountlow !== null
					) {
						throw new Error("Rust Host retired before RTCDataChannel callbacks and channel");
					}
				}
			} finally {
				first.close();
				second.close();
			}
		});
	} finally {
		clearTimeout(timer);
		child.kill("SIGTERM");
		const kill = setTimeout(() => child.kill("SIGKILL"), 10_000);
		try {
			const status = await exited;
			assert(status.success, `native web shutdown failed (${status.signal ?? status.code})`);
		} finally {
			clearTimeout(kill);
		}
	}
}

async function runtimeContract({ location }) {
	const binding = await import("/rooms_contract_proofs.js");
	await binding.default();
	const Original = globalThis.WebSocket;
	const sockets = [];
	globalThis.WebSocket = class extends Original {
		constructor(...args) {
			super(...args);
			sockets.push(this);
		}
	};
	try {
		await binding.rooms_browser_websocket_contract(location);
		if (!sockets.length) throw new Error("Runtime did not create a WebSocket");
		for (const socket of sockets) {
			if (
				socket.readyState !== Original.CLOSED || socket.onmessage !== null || socket.onclose !== null ||
				socket.onerror !== null || socket.onopen !== null
			) {
				throw new Error("Rust Runtime retired before its WebSocket and callbacks");
			}
		}
	} finally {
		globalThis.WebSocket = Original;
		for (const socket of sockets) socket.close();
	}
}

async function relayContract({ base }) {
	const binding = await import("/rooms_contract_proofs.js");
	binding.rooms_browser_relay_routes_contract();
	const Original = globalThis.WebSocket;
	for (const profile of ["keyed-relay", "noise-relay"]) {
		const sockets = [];
		let admitted;
		const ready = new Promise((resolve) => {
			admitted = resolve;
		});
		globalThis.WebSocket = class extends Original {
			constructor(...args) {
				super(...args);
				sockets.push(this);
				if (new URL(args[0]).pathname === "/register") {
					this.addEventListener("open", admitted, { once: true });
				}
			}
		};
		try {
			const origin = base.replace(/^http/, "ws");
			await binding.rooms_browser_relay_contract(`${origin}/relay`, `${origin}/register`, profile, ready);
			for (const socket of sockets) {
				if (
					socket.readyState !== Original.CLOSED || socket.onmessage !== null || socket.onclose !== null ||
					socket.onerror !== null || socket.onopen !== null
				) {
					throw new Error("Rust relay left its socket or callbacks live");
				}
			}
		} finally {
			globalThis.WebSocket = Original;
			for (const socket of sockets) socket.close();
		}
	}
}
