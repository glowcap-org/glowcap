// Tests exercise the production Rust exports without constructing a live Host.
import { loadApplication } from "../../web/ui/application.ts";

let ready: Promise<void> | null = null;
export function initializeApplication(): Promise<void> {
	return ready ??= (async () => {
		const artifact = await Deno.readFile(
			new URL("../../../../zig-out/wasm/rooms/rooms_browser_bg.wasm", import.meta.url),
		);
		await loadApplication(artifact);
	})();
}
