// Exercise the same application loading boundary and generated module as the page.
import { loadApplication } from "../../web/ui/application.ts";
await loadApplication(
	await Deno.readFile(new URL("../../../../zig-out/wasm/rooms/rooms_browser_bg.wasm", import.meta.url)),
);
