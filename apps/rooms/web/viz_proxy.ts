// Carries one browser viz socket to the live timeline endpoint, bytes only.
//
// The endpoint listens on a container-side port the browser's host may not
// publish, and an HTTPS page cannot open a bare `ws://` port at all, so the
// page reaches the timeline through its own origin and this leg moves the
// frames. It parses nothing and holds no capability: the endpoint still
// admits or refuses each socket by the `cap` query it carries, and its typed
// refusal codes travel back to the browser so a dead secret is erased there
// exactly as it would be on a direct connection.

/** How many bytes either side may hold unsent before the pair is torn down.
 * Trace frames are small; a queue this deep means the far side stopped
 * reading, and holding more only defers the same end. */
const MAX_BUFFERED_BYTES = 8 * 1024 * 1024;

/** The codes `WebSocket.close` accepts; anything else (an abnormal 1006, a
 * protocol 1002) closes plain and the far side reads it as gone. */
function passableCode(code: number): boolean {
	return code === 1000 || (code >= 3000 && code < 5000);
}

function closeWith(socket: WebSocket, code: number, reason: string): void {
	try {
		if (passableCode(code)) socket.close(code, reason.slice(0, 120));
		else socket.close();
	} catch {
		// Already closing or closed; either way it is going.
	}
}

/** Pipe `inbound` (an upgraded page socket) to the endpoint at `targetUrl`,
 * both directions, until either side closes. Messages arriving before the
 * outbound leg opens are held in order; a queue past `MAX_BUFFERED_BYTES`
 * on either side ends the pair rather than growing. */
export function pipeVizSocket(inbound: WebSocket, targetUrl: string): void {
	let outbound: WebSocket;
	try {
		outbound = new WebSocket(targetUrl);
	} catch {
		closeWith(inbound, 1011, "the timeline endpoint is not reachable");
		return;
	}
	inbound.binaryType = "arraybuffer";
	outbound.binaryType = "arraybuffer";
	const parked: (string | ArrayBuffer)[] = [];
	let parkedBytes = 0;
	let outboundOpen = false;

	const teardown = (code: number, reason: string): void => {
		closeWith(inbound, code, reason);
		closeWith(outbound, code, reason);
	};
	const forward = (to: WebSocket, data: string | ArrayBuffer): void => {
		if (to.readyState !== WebSocket.OPEN) return;
		to.send(data);
		if (to.bufferedAmount > MAX_BUFFERED_BYTES) {
			teardown(1011, "viz socket stopped draining");
		}
	};

	inbound.addEventListener("message", (event) => {
		const data = event.data as string | ArrayBuffer;
		if (outboundOpen) {
			forward(outbound, data);
			return;
		}
		parked.push(data);
		parkedBytes += typeof data === "string" ? data.length : data.byteLength;
		if (parkedBytes > MAX_BUFFERED_BYTES) {
			teardown(1011, "viz socket stopped draining");
		}
	});
	outbound.addEventListener("open", () => {
		outboundOpen = true;
		for (const data of parked.splice(0)) forward(outbound, data);
	});
	outbound.addEventListener("message", (event) => {
		forward(inbound, event.data as string | ArrayBuffer);
	});
	// A close on either side carries its code across, so the endpoint's typed
	// refusal reaches the browser; an error is a plain end.
	inbound.addEventListener("close", (event) => closeWith(outbound, event.code, event.reason));
	outbound.addEventListener("close", (event) => closeWith(inbound, event.code, event.reason));
	inbound.addEventListener("error", () => teardown(1011, "viz socket failed"));
	outbound.addEventListener("error", () => teardown(1011, "the timeline endpoint is not reachable"));
}
