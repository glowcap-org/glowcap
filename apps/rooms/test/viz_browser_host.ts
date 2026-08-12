import { startViz } from "../server/viz.ts";

const viz = startViz(0);
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
