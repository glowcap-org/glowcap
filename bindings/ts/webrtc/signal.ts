import { WEBRTC_MAX_SIGNAL_BYTES } from "@pancake/abi";

export function assertSignalBytes(kind: string, text: string): string {
	if (!fitsUtf8ByteCap(text, WEBRTC_MAX_SIGNAL_BYTES)) {
		throw new Error(`webrtc: ${kind} is too large`);
	}
	return text;
}

function fitsUtf8ByteCap(text: string, maxBytes: number): boolean {
	return utf8ByteLengthUpTo(text, maxBytes) <= maxBytes;
}

export function utf8ByteLengthUpTo(text: string, stopAfter?: number): number {
	let bytes = 0;
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 0x80) bytes += 1;
		else if (code < 0x800) bytes += 2;
		else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
			const next = text.charCodeAt(i + 1);
			if (next >= 0xdc00 && next <= 0xdfff) {
				bytes += 4;
				i++;
			} else {
				bytes += 3;
			}
		} else {
			bytes += 3;
		}
		if (stopAfter != null && bytes > stopAfter) return bytes;
	}
	return bytes;
}
