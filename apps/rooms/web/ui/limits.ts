// Protocol limits are generated from Rust. The display choices the page shares
// with the Deno client live in `lib/limits.ts`, beside their reasons.
import { applicationModule } from "./application.ts";
export * from "./application_data.ts";
export { AUTO_IMAGE_BYTES, MAX_SCROLLBACK, PLAIN_AWAY, TYPING_CLEAR_MS, TYPING_IDLE_MS } from "../../lib/limits.ts";

export function nickRefusal(nick: string): string | null {
	return applicationModule().nicknameRefusal(nick) ?? null;
}
export function lineCost(text: string): number {
	return applicationModule().lineBytes(text);
}
