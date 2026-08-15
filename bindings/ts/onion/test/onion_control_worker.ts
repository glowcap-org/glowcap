/// <reference no-default-lib="true" />
/// <reference lib="deno.worker" />

interface Start {
	serviceId: string;
	serviceKey: string;
}

self.onmessage = (event: MessageEvent<Start>) => {
	self.onmessage = null;
	void serve(event.data);
};

async function serve({ serviceId, serviceKey }: Start): Promise<void> {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	self.postMessage({
		kind: "ready",
		address: `127.0.0.1:${(listener.addr as Deno.NetAddr).port}`,
	});
	for await (const conn of listener) {
		void serveConnection(conn, serviceId, serviceKey).catch((error) => {
			self.postMessage({ kind: "error", error: String(error) });
		});
	}
}

async function serveConnection(
	conn: Deno.Conn,
	serviceId: string,
	serviceKey: string,
): Promise<void> {
	const decoder = new TextDecoder();
	const encoder = new TextEncoder();
	let pending = "";
	const buf = new Uint8Array(1024);
	try {
		while (true) {
			const n = await conn.read(buf);
			if (n === null) return;
			pending += decoder.decode(buf.subarray(0, n));
			let cut: number;
			while ((cut = pending.indexOf("\n")) >= 0) {
				const line = pending.slice(0, cut).replace(/\r$/, "");
				pending = pending.slice(cut + 1);
				if (line.startsWith("AUTHENTICATE")) {
					self.postMessage({ kind: "authenticate", line });
				}
				const reply = line.startsWith("ADD_ONION")
					? `250-ServiceID=${serviceId}\r\n250-PrivateKey=${serviceKey}\r\n250 OK\r\n`
					: "250 OK\r\n";
				await conn.write(encoder.encode(reply));
			}
		}
	} finally {
		conn.close();
	}
}
