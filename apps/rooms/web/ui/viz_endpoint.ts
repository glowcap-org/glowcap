// Same-origin routing is a browser concern; override admission belongs to Rust.
import { applicationModule } from "./application.ts";

export function originVizUrl(location: { protocol: string; host: string }): string {
	return `${location.protocol === "https:" ? "wss://" : "ws://"}${location.host}/viz`;
}
export function vizOverrideRefusal(value: string): string | null {
	return applicationModule().visualizerOverrideRefusal(value) ?? null;
}
