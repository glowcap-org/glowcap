// A loopback HTTP ingress that requires a browser cookie for WebSocket opens.
// The upstream is the production Rooms front. Native dials receive a login
// redirect, reproducing the admission boundary without external credentials.
export function loginRelay(upstreamPort: number) {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const origin = `http://127.0.0.1:${listener.addr.port}`;
	const connections = new Set<Deno.Conn>();
	const jobs = new Set<Promise<void>>();
	let closing = false;
	let refused = 0;
	const retire = (connection: Deno.Conn) => {
		if (connections.delete(connection)) connection.close();
	};
	async function serve(client: Deno.Conn) {
		let upstream: Deno.Conn | null = null;
		try {
			const buffer = new Uint8Array(16 * 1024);
			let length = 0;
			let headers = "";
			while (!headers.includes("\r\n\r\n")) {
				if (length === buffer.length) throw new Error("login ingress request headers exceeded the bound");
				const read = await client.read(buffer.subarray(length));
				if (read === null) return;
				length += read;
				headers = new TextDecoder().decode(buffer.subarray(0, length));
			}
			if (/\r\nUpgrade:\s*websocket\r\n/i.test(headers) && !/\bproof_login=yes\b/.test(headers)) {
				refused++;
				await writeAll(
					client,
					new TextEncoder().encode(
						"HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
					),
				);
				return;
			}
			upstream = await Deno.connect({ hostname: "127.0.0.1", port: upstreamPort });
			connections.add(upstream);
			await writeAll(upstream, buffer.subarray(0, length));
			const transfers = [copy(client, upstream), copy(upstream, client)];
			try {
				await Promise.race(transfers);
			} finally {
				retire(client);
				retire(upstream);
				await Promise.allSettled(transfers);
			}
		} finally {
			retire(client);
			if (upstream) retire(upstream);
		}
	}
	const accepted = (async () => {
		try {
			for await (const client of listener) {
				connections.add(client);
				const job = serve(client).catch((error) => {
					if (!closing) console.error("login ingress connection ended:", error);
				}).finally(() => jobs.delete(job));
				jobs.add(job);
			}
		} catch (error) {
			if (!closing) throw error;
		}
	})();
	return {
		origin,
		relay: origin.replace("http:", "ws:") + "/relay",
		get refused() {
			return refused;
		},
		async close() {
			closing = true;
			listener.close();
			for (const connection of connections) retire(connection);
			await accepted;
			await Promise.all(jobs);
		},
	};
}

async function writeAll(connection: Deno.Conn, bytes: Uint8Array) {
	let offset = 0;
	while (offset < bytes.length) offset += await connection.write(bytes.subarray(offset));
}

async function copy(source: Deno.Conn, target: Deno.Conn) {
	const buffer = new Uint8Array(16 * 1024);
	let read = await source.read(buffer);
	while (read !== null) {
		await writeAll(target, buffer.subarray(0, read));
		read = await source.read(buffer);
	}
}
