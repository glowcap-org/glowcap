import { INTERNAL } from "@glowcap/abi";
import { checkHost, GlowcapError } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import type { Ptr } from "../internal/ffi/runtime.ts";
import { L } from "../internal/layout.ts";
import { ab, outPointer, outU32, outUsize, readBytes } from "../internal/seam.ts";
import { type SessionProfile, sessionProfileFromAbi } from "../value.ts";
import { type PartnerIdentity, provenanceFromAbi } from "./identity.ts";

const utf8Decoder = new TextDecoder();

/** Project the negotiated wire profile from the FFI session boundary. */
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

/** Decode the exact netlayer symbol retained by the FFI session. */
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

/** Copy the verified partner claim before a later FFI call can invalidate it. */
export function readPartnerIdentity(ptr: Ptr): PartnerIdentity {
	const buf = new Uint8Array(L.PARTNER_IDENTITY_SIZE);
	checkHost(hostS.glowcap_host_session_partner_identity(ptr, ab(buf)));
	// The views the call filled in are session-owned and a later call can
	// invalidate them, so every field is copied here (`readBytes` owns its
	// result) before this returns.
	const dv = new DataView(buf.buffer);
	const view = (off: number, lenOff: number): Uint8Array => readBytes(L.getPtr(dv, off), L.getUsize(dv, lenOff));
	return {
		sessionKey: view(
			L.PARTNER_IDENTITY_SESSION_KEY_OFF,
			L.PARTNER_IDENTITY_SESSION_KEY_LEN_OFF,
		),
		designator: utf8Decoder.decode(view(
			L.PARTNER_IDENTITY_DESIGNATOR_OFF,
			L.PARTNER_IDENTITY_DESIGNATOR_LEN_OFF,
		)),
		locatorRecord: view(
			L.PARTNER_IDENTITY_LOCATOR_RECORD_OFF,
			L.PARTNER_IDENTITY_LOCATOR_RECORD_LEN_OFF,
		),
		provenance: provenanceFromAbi(
			dv.getUint32(L.PARTNER_IDENTITY_PROVENANCE_OFF, true),
		),
	};
}
