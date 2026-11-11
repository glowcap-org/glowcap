import * as tcp from "@glowcap/tcp";
import process from "node:process";
import { ensureRuntimeReady, Runtime } from "../runtime/mod.ts";
import { ok, runtime } from "./scenarios/support.ts";
import * as runtimeSurface from "./scenarios/runtime_surface.ts";
import * as bunRefusals from "./scenarios/bun_refusals.ts";
import * as enliven from "./scenarios/enliven.ts";
import * as roundtrip from "./scenarios/roundtrip.ts";
import * as referenceOwnership from "./scenarios/reference_ownership.ts";
import * as pipeline from "./scenarios/pipeline.ts";
import * as lifecycle from "./scenarios/lifecycle.ts";
import * as driver from "./scenarios/driver.ts";
import * as hostActors from "./scenarios/host_actors.ts";

// Bun resolves its FFI adapter asynchronously; make it ready before every
// synchronous locator/FFI call. A no-op on Deno (resolved at import).
await ensureRuntimeReady();

await runtimeSurface.run();

// Bun's FFI runs calls on the JavaScript thread. It can use the
// byte-fed client path, but it cannot host a driver listener or own a
// blocking transport lifecycle until its adapter gains a worker executor.
// Prove that boundary, then stop before the Deno-only listener scenarios.
if (runtime === "bun") {
	await bunRefusals.run();
	ok("proved Host and locator ABI surfaces and refused parking FFI lifecycles");
	process.exit(0);
}

await using managed = await Runtime.open({ providers: [tcp.provider()] });
await roundtrip.run(managed);
await enliven.run(managed);
await pipeline.run(managed);
await referenceOwnership.run(managed);
await lifecycle.run(managed);
await driver.run(managed);
await hostActors.run(managed);
