import { startViz } from "../server/viz.ts";

// The endpoint admits only sockets presenting its capability, so this harness
// mints one for its own run; the printed sturdyref carries it as its swissnum.
const swiss = [...crypto.getRandomValues(new Uint8Array(32))]
	.map((byte) => byte.toString(16).padStart(2, "0"))
	.join("");
const viz = startViz(0, swiss);
const [port, sturdyref] = await Promise.all([viz.ready, viz.sturdyref]);
console.log(JSON.stringify({ port, sturdyref }));

await new Promise<void>((resolve) => {
	const stop = () => {
		Deno.removeSignalListener("SIGTERM", stop);
		resolve();
	};
	Deno.addSignalListener("SIGTERM", stop);
});
viz.close();
