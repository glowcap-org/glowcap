import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";

const LOGIN_COOKIE = { name: "rooms_http_contract", value: "confirmed" };

// WebRTC configuration: ICE policy reads, fresh certificates, and cancellation.
export function rtcConfigurationProof() {
	let rotating = 0, retry = 0;
	// The origin the cross-origin read named, as the browser sent it.
	let elsewhere = null;
	let closed;
	const pendingClosed = new Promise((resolve) => {
		closed = resolve;
	});
	function serve(request, response) {
		if (!request.url.startsWith("/ice/")) return false;
		assert.equal(
			request.headers.cookie,
			request.url === "/ice/elsewhere" ? undefined : `${LOGIN_COOKIE.name}=${LOGIN_COOKIE.value}`,
			"ICE reads must use the login only on the page's own origin",
		);
		response.setHeader("Content-Type", "application/json");
		switch (request.url) {
			case "/ice/elsewhere":
				elsewhere = request.headers.origin ?? "(no origin header)";
				response.setHeader("Access-Control-Allow-Origin", elsewhere);
				response.setHeader("Vary", "Origin");
				response.end(
					JSON.stringify([{
						urls: ["turn:fixture.invalid"],
						username: "fixture",
						credential: "elsewhere",
					}]),
				);
				break;
			case "/ice/rotating":
				response.end(
					JSON.stringify([{
						urls: ["turn:fixture.invalid"],
						username: "fixture",
						credential: `credential-${++rotating}`,
					}]),
				);
				break;
			case "/ice/retry":
				response.statusCode = ++retry === 1 ? 503 : 200;
				response.end("[]");
				break;
			case "/ice/invalid":
				response.end('[{"urls":"stun:a","urls":"stun:b"}]');
				break;
			case "/ice/oversize":
				response.writeHead(200, { "Content-Length": "10000000" });
				response.end("[]");
				break;
			case "/ice/oversize-stream":
				response.writeHead(200);
				response.write(" ");
				response.end(Buffer.alloc(5 * 1024 * 1024, 0x20));
				break;
			case "/ice/pending":
				response.on("close", closed);
				response.writeHead(200);
				response.write("[");
				break;
			default:
				response.writeHead(404);
				response.end();
		}
		return true;
	}
	return {
		serve,
		async check(page) {
			const otherOriginServer = createServer((request, response) => {
				if (serve(request, response)) return;
				response.writeHead(404);
				response.end();
			});
			let deadline;
			try {
				otherOriginServer.listen(0, "127.0.0.1");
				await once(otherOriginServer, "listening");
				// Another port on the same host is cross-origin but still same-site:
				// SameSite cookies cannot conceal accidentally included credentials.
				const origin = new URL(page.url()).origin;
				const across = new URL(`http://127.0.0.1:${otherOriginServer.address().port}/ice/elsewhere`);
				assert.notEqual(across.origin, origin);
				assert.equal(across.hostname, new URL(origin).hostname);
				await page.context().addCookies([{ ...LOGIN_COOKIE, url: origin }]);
				await Promise.race([
					(async () => {
						await page.evaluate(async (across) => {
							const binding = await import("/rooms_contract_proofs.js");
							const generate = RTCPeerConnection.generateCertificate;
							const { promise, reject } = Promise.withResolvers();
							RTCPeerConnection.generateCertificate = () => promise;
							try {
								await binding.rooms_browser_certificate_capacity(() => {
									RTCPeerConnection.generateCertificate = generate;
									reject(new DOMException("fixture certificate refusal", "OperationError"));
								});
							} finally {
								RTCPeerConnection.generateCertificate = generate;
							}
							const configurations = await binding.rooms_browser_ice_contract(across);
							const fingerprints = (certificates) => {
								if (certificates?.length !== 1 || !(certificates[0] instanceof RTCCertificate)) {
									throw new Error("Rooms must supply one browser certificate per peer");
								}
								const ids = certificates[0].getFingerprints().map(({ algorithm, value }) =>
									algorithm + " " + value
								);
								if (!ids.length) throw new Error("the supplied certificate has no fingerprints");
								return ids.sort().join(",");
							};
							const identities = configurations.map((config) => fingerprints(config.certificates));
							if (identities.length !== 2 || identities[0] === identities[1]) {
								throw new Error("concurrent peers must receive two distinct certificates");
							}
							const prototype = ReadableStreamDefaultReader.prototype;
							const read = prototype.read;
							let reads = 0, active = 0, notify;
							const pending = new Promise((resolve) => {
								notify = resolve;
							});
							prototype.read = function (...args) {
								const result = read.apply(this, args);
								active++;
								result.then(() => active--, () => active--);
								// The first read consumes '['. The next is
								// pending: the server never finishes it.
								if (++reads === 2) notify();
								return result;
							};
							try {
								await binding.rooms_browser_ice_cancel_contract(pending);
								if (active !== 0) throw new Error("ICE close returned with a pending browser read");
							} finally {
								prototype.read = read;
							}
						}, across.href);
						await pendingClosed;
					})(),
					new Promise((_, reject) => {
						deadline = setTimeout(() => reject(new Error("browser ICE contract timed out")), 15_000);
					}),
				]);
				assert.equal(
					elsewhere,
					origin,
					"the cross-origin ICE read must reach the server with the page's origin",
				);
				assert.equal(
					rotating,
					2,
					"concurrent reads must share one attempt; the next attempt refreshes credentials",
				);
				assert.equal(retry, 2, "a failed request must permit a fresh attempt");
			} finally {
				clearTimeout(deadline);
				if (otherOriginServer.listening) {
					await new Promise((resolve, reject) =>
						otherOriginServer.close((error) => error ? reject(error) : resolve())
					);
				}
			}
		},
	};
}
