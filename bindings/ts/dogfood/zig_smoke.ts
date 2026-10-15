import * as tcp from "@glowcap/tcp";
import process from "node:process";
import { ensureRuntimeReady, Runtime } from "../runtime/mod.ts";
import { ok, runtime } from "./smoke/support.ts";
import * as shared from "./smoke/shared.ts";
import * as bunRefusals from "./smoke/bun_refusals.ts";
import * as enliven from "./smoke/enliven.ts";
import * as roundtrip from "./smoke/roundtrip.ts";
import * as pipeline from "./smoke/pipeline.ts";
import * as lifecycle from "./smoke/lifecycle.ts";
import * as driver from "./smoke/driver.ts";

// Bun resolves its FFI adapter asynchronously; make it ready before every
// synchronous locator/FFI call. A no-op on Deno (resolved at import).
await ensureRuntimeReady();

await shared.run();

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
await lifecycle.run(managed);
await driver.run(managed);
