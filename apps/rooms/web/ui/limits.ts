// Protocol limits are generated from Rust. These local choices govern display.
import { applicationModule } from "./application.ts";
export * from "./application_data.ts";

export const MAX_SCROLLBACK = 2000;
export const AUTO_IMAGE_BYTES = 2 * 1024 * 1024;
export const PLAIN_AWAY = "away";
export const TYPING_IDLE_MS = 4_000;
export const TYPING_CLEAR_MS = TYPING_IDLE_MS + 2_000;

export function nickRefusal(nick: string): string | null {
	return applicationModule().nicknameRefusal(nick) ?? null;
}
export function lineCost(text: string): number {
	return applicationModule().lineBytes(text);
}
