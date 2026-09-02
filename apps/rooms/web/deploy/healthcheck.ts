// Whether this container is serving, which is not the same as running.
//
// `serve.ts` stays up while the room server it supervises is starting, gone, or
// refusing to start, and a container that is up and useless looks exactly like a
// working one from the outside: an operator finds out from somebody in the room.
// `/locator` is the one answer that needs both halves to be true — the page is
// being served, and the room server has announced itself.
//
// Deno is the only tool in this image, so this is the probe. It is a file rather
// than an inline `deno eval` because `eval` takes no permission flags, and a
// probe that cannot ask the question reads as a dead container.

const port = Deno.env.get("GLOWCAP_ROOMS_HTTP_PORT") ?? "8000";
const at = `http://127.0.0.1:${port}/locator`;

try {
	const answer = await fetch(at, { signal: AbortSignal.timeout(5_000) });
	// Read the body out, so the connection closes here rather than at a timeout.
	const said = (await answer.text()).trim();
	if (!answer.ok) {
		console.error(`rooms: not serving yet: ${at} answered ${answer.status} ${JSON.stringify(said)}`);
		Deno.exit(1);
	}
	if (said.length === 0) {
		console.error(`rooms: ${at} answered with no locator at all`);
		Deno.exit(1);
	}
} catch (err) {
	console.error(`rooms: could not reach ${at}: ${err instanceof Error ? err.message : err}`);
	Deno.exit(1);
}
