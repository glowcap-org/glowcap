// The one PNG the page proofs post, shared by the posting phase and the
// change phase so the two halves of the file proof measure the same bytes.
//
// A real 4x2 PNG, written out as bytes rather than base64 so the file that
// reaches the room is the file this test can name byte for byte. Its chunk
// CRCs are correct, which matters more than it looks: an `<img>` will draw
// a PNG with a broken CRC, and `createImageBitmap` — which is what the page
// measures a picture with before posting it — will not. A fixture that only
// the lenient path accepts tests the lenient path.
//
// Four by two rather than square, so asserting the reserved shape asserts
// that the numbers travelled rather than that something was set.
export const png = [
	0x89,
	0x50,
	0x4e,
	0x47,
	0x0d,
	0x0a,
	0x1a,
	0x0a,
	0x00,
	0x00,
	0x00,
	0x0d,
	0x49,
	0x48,
	0x44,
	0x52,
	0x00,
	0x00,
	0x00,
	0x04,
	0x00,
	0x00,
	0x00,
	0x02,
	0x08,
	0x06,
	0x00,
	0x00,
	0x00,
	0x7f,
	0xa8,
	0x7d,
	0x63,
	0x00,
	0x00,
	0x00,
	0x20,
	0x49,
	0x44,
	0x41,
	0x54,
	0x78,
	0xda,
	0x63,
	0x60,
	0x60,
	0x68,
	0xf8,
	0x6f,
	0x03,
	0xc4,
	0x15,
	0x40,
	0xbc,
	0x05,
	0x88,
	0x19,
	0x18,
	0xa2,
	0x80,
	0x02,
	0x40,
	0x5c,
	0x01,
	0xc4,
	0x5b,
	0x80,
	0x18,
	0x00,
	0xf4,
	0xf6,
	0x10,
	0x31,
	0x6f,
	0x74,
	0x48,
	0x30,
	0x00,
	0x00,
	0x00,
	0x00,
	0x49,
	0x45,
	0x4e,
	0x44,
	0xae,
	0x42,
	0x60,
	0x82,
];

import { Buffer } from "node:buffer";
import { deflateSync } from "node:zlib";

const CRC_TABLE = new Uint32Array(256).map((_, n) => {
	let c = n;
	for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
	return c >>> 0;
});

function crc32(bytes: Uint8Array): number {
	let c = 0xffffffff;
	for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
	return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type: string, data: Uint8Array): Uint8Array {
	const out = new Uint8Array(12 + data.length);
	const view = new DataView(out.buffer);
	view.setUint32(0, data.length);
	for (let i = 0; i < 4; i += 1) out[4 + i] = type.charCodeAt(i);
	out.set(data, 8);
	view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
	return out;
}

/** A valid PNG of any size, for the one proof that needs a picture larger
 * than the stage: the fixture above is deliberately tiny, and actual size on
 * it is the same picture as fitted. Solid colour, so the deflate stays a few
 * kilobytes however many pixels it names; CRCs are correct for the same
 * reason the fixture's are. */
export function bigPng(width: number, height: number): Uint8Array {
	const header = new Uint8Array(13);
	const view = new DataView(header.buffer);
	view.setUint32(0, width);
	view.setUint32(4, height);
	header[8] = 8; // bit depth
	header[9] = 2; // colour type: RGB
	const raw = new Uint8Array(height * (1 + width * 3));
	for (let y = 0; y < height; y += 1) {
		const row = y * (1 + width * 3);
		for (let x = 0; x < width; x += 1) {
			raw[row + 1 + x * 3] = 0x33;
			raw[row + 2 + x * 3] = 0x66;
			raw[row + 3 + x * 3] = 0x99;
		}
	}
	const signature = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
	const parts = [
		signature,
		pngChunk("IHDR", header),
		pngChunk("IDAT", new Uint8Array(deflateSync(Buffer.from(raw)))),
		pngChunk("IEND", new Uint8Array(0)),
	];
	const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
	let at = 0;
	for (const part of parts) {
		out.set(part, at);
		at += part.length;
	}
	return out;
}
