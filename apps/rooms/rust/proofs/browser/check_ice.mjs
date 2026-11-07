import assert from "node:assert/strict";

// Real HTTP bodies: Fetch and stream cancellation remain browser operations.
export function iceFixtures() {
	let rotating = 0, retry = 0;
	// The origin the cross-origin read named, as the browser sent it.
	let elsewhere = null;
	let closed;
	const pendingClosed = new Promise((resolve) => {
		closed = resolve;
	});
	return {
		serve(request, response) {
			if (!request.url.startsWith("/ice/")) return false;
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
		},
		async check(page) {
			// The same server by its other loopback name is another origin to the page.
			const origin = new URL(page.url()).origin;
			const across = new URL("/ice/elsewhere", origin);
			across.hostname = across.hostname === "localhost" ? "127.0.0.1" : "localhost";
			let deadline;
			try {
				await Promise.race([
					(async () => {
						await page.evaluate(async (across) => {
							const binding = await import("/rooms_contract_proofs.js");
							await binding.rooms_browser_ice_contract(across);
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
			}
		},
	};
}
