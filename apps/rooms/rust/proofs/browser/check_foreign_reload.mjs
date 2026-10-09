import assert from "node:assert/strict";

// Pages own their RTC objects and Rust runtimes. The coordinator carries only
// signaling, live Host keys, URI strings and the encoded resource across reload.
async function bounded(label, action) {
	let timer;
	try {
		return await Promise.race([
			action(),
			new Promise((_, reject) => {
				timer = setTimeout(() => reject(new Error(`${label} timed out`)), 30_000);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
}

// This function is serialized into each page. Gathering and callback ownership
// end together; no detached candidate forwarding task survives a phase.
async function gather(peer) {
	if (peer.iceGatheringState === "complete") return;
	let timer;
	try {
		await new Promise((resolve, reject) => {
			timer = setTimeout(() => reject(new Error("RTC gathering timed out")), 5000);
			peer.onicegatheringstatechange = () => {
				if (peer.iceGatheringState === "complete") resolve();
			};
		});
	} finally {
		clearTimeout(timer);
		peer.onicegatheringstatechange = null;
	}
}

async function gatherPage(page) {
	const peer = await page.evaluateHandle(() => foreignPeer);
	try {
		await page.evaluate(gather, peer);
	} finally {
		await peer.dispose();
	}
}

export async function checkSessionForeignReload(browser, source, url) {
	const exporter = await browser.newPage();
	exporter.on("pageerror", (error) => console.error(error));
	exporter.on("console", (message) => {
		if (message.type() === "error") console.error(message.text());
	});
	try {
		await exporter.goto(url);
		await exporter.evaluate(async () => {
			const binding = await import("/rooms_contract_proofs.js");
			await binding.default();
			let ready;
			let failed;
			globalThis.foreignReady = new Promise((resolve, reject) => {
				ready = resolve;
				failed = reject;
			});
			globalThis.foreignExporterReady = (location, uris) => ready({ location, uris });
			// Exactly two consuming arrivals exist before Rust first polls.
			// Retirement cannot accidentally recycle the previous channel.
			globalThis.foreignArrivals = Array.from({ length: 2 }, () => {
				let deliver;
				const promise = new Promise((resolve) => deliver = resolve);
				return { promise, deliver };
			});
			let arrival = 0;
			globalThis.nextForeignChannel = () => {
				if (arrival === foreignArrivals.length) throw new Error("unexpected channel arrival");
				return foreignArrivals[arrival++].promise;
			};
			globalThis.foreignSourceFinished = () => globalThis.foreignPhase.finished;
			globalThis.foreignExporterRetired = () => globalThis.foreignPhase.retire();
			globalThis.foreignChannelPrepared = () => globalThis.foreignPhase.prepare();
			// One continuously polled LocalSet owns the exporter and publications.
			globalThis.foreignExporterTask = binding.rooms_session_foreign_exporter();
			globalThis.foreignExporterTask.catch((error) => {
				failed(error);
				globalThis.foreignPhase?.fail(error);
			});
		});
		const { location, uris } = await bounded("exporter readiness", () => exporter.evaluate(() => foreignReady));
		assert.equal(uris.length, 3592);
		let resource = [];
		for (let phase = 0; phase < 2; phase++) {
			if (phase === 1) await source.reload();
			resource = await bounded(`foreign source phase ${phase}`, async () => {
				await source.evaluate(async () => {
					const binding = await import("/rooms_contract_proofs.js");
					await binding.default();
					let key;
					globalThis.foreignSourceKey = new Promise((resolve) => key = resolve);
					globalThis.foreignSourceAllowed = new Promise((resolve) => {
						globalThis.allowForeignSource = resolve;
					});
					globalThis.foreignSourceReady = (value) => {
						key(value);
						return foreignSourceAllowed;
					};
					globalThis.foreignPeer = new RTCPeerConnection({ iceServers: [] });
					globalThis.foreignChannel = foreignPeer.createDataChannel("captp");
					await foreignPeer.setLocalDescription(await foreignPeer.createOffer());
				});
				await gatherPage(source);
				const offer = await source.evaluate(() => foreignPeer.localDescription.toJSON());
				await exporter.evaluate(async ({ offer, phase }) => {
					let channel;
					let key;
					let finish;
					let retire;
					let fail;
					let prepare;
					const prepared = new Promise((resolve) => prepare = resolve);
					const received = new Promise((resolve) => channel = resolve);
					const pinned = new Promise((resolve) => key = resolve);
					const retired = new Promise((resolve, reject) => {
						retire = resolve;
						fail = reject;
					});
					globalThis.foreignPhase = {
						key,
						prepared,
						prepare,
						finished: new Promise((resolve) => finish = resolve),
						finish: () => finish(),
						retired,
						retire,
						fail,
					};
					foreignArrivals[phase].deliver(Promise.all([received, pinned]));
					globalThis.foreignPeer = new RTCPeerConnection({ iceServers: [] });
					foreignPeer.ondatachannel = (event) => {
						foreignPeer.ondatachannel = null;
						globalThis.foreignChannel = event.channel;
						channel(event.channel);
					};
					await foreignPeer.setRemoteDescription(offer);
					await foreignPeer.setLocalDescription(await foreignPeer.createAnswer());
				}, { offer, phase });
				await gatherPage(exporter);
				const answer = await exporter.evaluate(() => foreignPeer.localDescription.toJSON());
				await source.evaluate((answer) => foreignPeer.setRemoteDescription(answer), answer);
				// Source exposes its actual live Host key before dial. The controlled
				// realizer pins that peer on the corresponding exporter-side channel.
				const result = source.evaluate(async ({ location, uris, resource }) => {
					const binding = await import("/rooms_contract_proofs.js");
					return Array.from(
						await binding.rooms_session_foreign_reload(
							foreignChannel,
							location,
							uris,
							new Uint8Array(resource),
						),
					);
				}, { location, uris, resource });
				// Observe failure even if it precedes the key handoff.
				result.catch(() => {});
				const key = await Promise.race([
					source.evaluate(() => foreignSourceKey),
					result.then(() => {
						throw new Error("source finished before key handoff");
					}),
				]);
				await exporter.evaluate(async (key) => {
					foreignPhase.key(key);
					await foreignPhase.prepared;
				}, key);
				await source.evaluate(() => allowForeignSource());
				return await result;
			});
			assert.equal(resource.length, 99);
			await bounded("exporter session retirement", () =>
				exporter.evaluate(async () => {
					foreignPhase.finish();
					await foreignPhase.retired;
				}));
			for (const page of [source, exporter]) {
				await page.evaluate(() => {
					const channel = foreignChannel;
					if (
						channel.readyState !== "closed" ||
						["onmessage", "onclose", "onerror", "onopen", "onbufferedamountlow"].some((name) =>
							channel[name] !== null
						)
					) {
						throw new Error("session retired before RTC channel and callbacks");
					}
					foreignPeer.close();
				});
			}
		}
		await bounded("exporter shutdown", () => exporter.evaluate(() => foreignExporterTask));
	} finally {
		await exporter.close();
		await source.evaluate(() => globalThis.foreignPeer?.close());
	}
}
