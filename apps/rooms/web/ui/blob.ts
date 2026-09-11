// Materialize only the requested byte view for the browser media viewer.
export function blobOf(bytes: Uint8Array, mime: string): Blob {
	const own = new Uint8Array(bytes.byteLength);
	own.set(bytes);
	return new Blob([own.buffer], { type: mime });
}
