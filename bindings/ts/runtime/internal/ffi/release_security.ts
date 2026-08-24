/** Hygiene and transport-policy failures must fail closed even when archive
 * discovery is otherwise allowed to fall through to another rung. */
export class HardFailError extends Error {
	override readonly name = "HardFailError";
}

export function failArchiveSecurity(message: string): never {
	throw new HardFailError(message);
}

export function requireSecureReleaseUrl(base: string, allowInsecure: boolean): void {
	if (base.startsWith("https://") || allowInsecure) return;
	failArchiveSecurity(`refusing non-HTTPS release base URL: ${base}`);
}

export function curlTransportArgs(url: string, allowInsecure: boolean): string[] {
	if (allowInsecure && !url.startsWith("https://")) return [];
	return ["--proto", "=https", "--tlsv1.2"];
}
