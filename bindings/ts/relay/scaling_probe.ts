// A thin instrument wrapper around the reference relay for the scaling
// measurement (`scaling_bench.ts`). It starts the real relay unchanged by
// importing `serve.ts` (which reads its port from argv and prints
// `DENO-RELAY-READY <port>`), then reports the relay process's own resident
// memory on an interval. The load harness runs in a separate process and reads
// these lines, so the memory it measures is the relay's alone, with none of the
// harness's own connection objects mixed in.
//
// Reporting from inside the process uses `Deno.memoryUsage().rss`, which needs no
// permission and works on every platform, so the harness never reaches into
// `/proc` and never needs `--allow-all`.

// Start the real relay. `serve.ts` calls `Deno.serve` at module load and prints
// `DENO-RELAY-READY <port>`, so the relay under measurement is byte-for-byte the
// one the demo runs, not a copy.
import "./serve.ts";

// Report the relay process's own resident memory on an interval. This needs no
// permission and works on every platform, so the harness never reaches into
// /proc (which Deno gates behind --allow-all) and stays on scoped permissions.
setInterval(() => {
	console.log(`RELAY-RSS ${Deno.memoryUsage().rss}`);
}, 200);
