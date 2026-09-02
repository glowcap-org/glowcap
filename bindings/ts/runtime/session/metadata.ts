import { INTERNAL } from "@glowcap/abi";
import { checkHost, GlowcapError } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import type { Ptr } from "../internal/ffi/runtime.ts";
import { L } from "../internal/layout.ts";
import { ab, outPointer, outU32, outUsize, readBytes } from "../internal/seam.ts";
import { type SessionProfile, sessionProfileFromAbi } from "../value.ts";

/** Project the negotiated wire profile from the native session boundary. */
export function readSessionProfile(ptr: Ptr): SessionProfile {
	const version = new Uint8Array(4);
	const codec = new Uint8Array(4);
	const features = new Uint8Array(4);
	checkHost(hostS.glowcap_host_session_profile(
		ptr,
		ab(version),
		ab(codec),
		ab(features),
	));
	return sessionProfileFromAbi(outU32(version), outU32(codec), outU32(features));
}

/** Decode the exact netlayer symbol retained by the native session. */
export function readSessionTransportName(ptr: Ptr): string {
	const name = new Uint8Array(L.ptrSize);
	const len = new Uint8Array(L.ptrSize);
	checkHost(hostS.glowcap_host_session_transport_name(ptr, ab(name), ab(len)));
	const bytes = readBytes(outPointer(name), outUsize(len));
	try {
		return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
	} catch (error) {
		throw new GlowcapError(
			INTERNAL,
			`glowcap ABI returned a non-UTF-8 session transport name: ${String(error)}`,
		);
	}
}
