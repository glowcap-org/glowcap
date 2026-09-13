// A loopback port nothing is listening on.
//
// Bind port zero, read what the kernel handed out, and release it. The window
// between release and the server's own bind is the ordinary race; a stateful
// server that must come back on the same number retries the one refusal that
// window produces (see `restartStatefulServer`).

export function freePort(): number {
	const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
	const port = (listener.addr as Deno.NetAddr).port;
	listener.close();
	return port;
}
