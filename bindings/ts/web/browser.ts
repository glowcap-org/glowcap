/** Prebuilt browser SDK entry. The release bundles these exports into one
 * module so every transport shares the adapter installed by `init`. */
export { init } from "./mod.ts";
export type { WasmSource, WebInitOptions, WebRuntime } from "./mod.ts";
export * as relay from "@glowcap/relay";
export * as webrtc from "@glowcap/webrtc";
