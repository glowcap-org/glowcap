import { WEBRTC_MAX_SIGNAL_BYTES } from "@glowcap/abi";
import { utf8ByteLengthUpTo } from "@glowcap/runtime";

export function assertSignalBytes(kind: string, text: string): string {
	if (!fitsUtf8ByteCap(text, WEBRTC_MAX_SIGNAL_BYTES)) {
		throw new Error(`webrtc: ${kind} is too large`);
	}
	return text;
}

function fitsUtf8ByteCap(text: string, maxBytes: number): boolean {
	return utf8ByteLengthUpTo(text, maxBytes) <= maxBytes;
}
