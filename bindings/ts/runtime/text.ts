// UTF-8 measurement for the byte caps the ABI states in bytes while a caller
// holds a JavaScript string.

/** UTF-8 bytes of `text`, counted without encoding it. Counting stops once the
 * total passes `stopAfter`, so a cap check (`utf8ByteLengthUpTo(text, cap) <=
 * cap`) never walks a long string past its first byte over the cap. */
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
