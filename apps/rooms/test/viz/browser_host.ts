import { startViz } from "../../server/viz.ts";
import { VIZ_PUBLISH_PATH, vizCapUrl } from "../../lib/viz_publish.ts";

// The endpoint admits only sockets presenting its capability, so this harness
// mints one for its own run; the printed sturdyref carries it as its swissnum.
const swiss = [...crypto.getRandomValues(new Uint8Array(32))]
	.map((byte) => byte.toString(16).padStart(2, "0"))
	.join("");
const viz = startViz(0, swiss, () => {});
const [port, sturdyref] = await Promise.all([viz.ready, viz.sturdyref]);
// Producers need that capability too, not only viewers, and the swiss is not
// the sturdyref's swissnum spelled the same way. Handing out a URL that is
// ready to open keeps both facts here, with the harness that minted the
// capability, rather than in every caller that wants to write a record.
const publish = vizCapUrl(`ws://127.0.0.1:${port}${VIZ_PUBLISH_PATH}`, swiss);
console.log(JSON.stringify({ port, sturdyref, publish }));

await new Promise<void>((resolve) => {
	const stop = () => {
		Deno.removeSignalListener("SIGTERM", stop);
		resolve();
	};
	Deno.addSignalListener("SIGTERM", stop);
});
viz.close();
