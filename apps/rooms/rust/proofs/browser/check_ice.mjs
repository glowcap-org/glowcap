import assert from "node:assert/strict";

// Real HTTP bodies: Fetch and stream cancellation remain browser operations.
export function iceFixtures() {
	let rotating = 0, retry = 0;
	let closed;
	const pendingClosed = new Promise((resolve) => {
		closed = resolve;
	});
	return {
		serve(request, response) {
			if (!request.url.startsWith("/ice/")) return false;
			response.setHeader("Content-Type", "application/json");
			switch (request.url) {
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
			let deadline;
			try {
				await Promise.race([
					(async () => {
						await page.evaluate(async () => {
							const binding = await import("/rooms_contract_proofs.js");
							await binding.rooms_browser_ice_contract();
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
						});
						await pendingClosed;
					})(),
					new Promise((_, reject) => {
						deadline = setTimeout(() => reject(new Error("browser ICE contract timed out")), 15_000);
					}),
				]);
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
