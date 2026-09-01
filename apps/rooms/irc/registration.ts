// Bounded IRC registration vocabulary shared by configuration and the socket
// driver. It contains no environment or network access.

const SASL_ACCOUNT_BYTES = 64;
const SASL_PASSWORD_BYTES = 256;

export interface SaslPlainCredentials {
	readonly account: string;
	readonly password: string;
}

export function validateIrcNick(nick: string): void {
	if (!/^[A-Za-z[\]\\`_^{|}][A-Za-z0-9[\]\\`_^{|}-]{0,27}$/.test(nick)) {
		throw new Error("IRC nickname must be 1..28 ASCII nickname characters and begin with a letter or special");
	}
}

/** An IRC-legal nick for a Rooms name that is not one, derived from the name so
 * the same person is the same nick every time.
 *
 * Beside `validateIrcNick` because it is the other half of that question: one
 * says what IRC will accept, this makes something it accepts. Both halves of
 * the IRC edge ask it — the front projecting a Rooms member onto a client's
 * screen, and the bridge when a member's chosen nick is not one IRC allows. */
export function projectedNick(name: string): string {
	let hash = 0x811c9dc5;
	for (const byte of new TextEncoder().encode(name)) {
		hash ^= byte;
		hash = Math.imul(hash, 0x01000193) >>> 0;
	}
	return `rooms-${hash.toString(16).padStart(8, "0")}`;
}

export function validateSaslPlain(credentials: SaslPlainCredentials): void {
	const encoder = new TextEncoder();
	const accountBytes = encoder.encode(credentials.account).length;
	const passwordBytes = encoder.encode(credentials.password).length;
	if (accountBytes < 1 || accountBytes > SASL_ACCOUNT_BYTES || credentials.account.includes("\0")) {
		throw new Error(`IRC SASL account must be 1..${SASL_ACCOUNT_BYTES} UTF-8 bytes without NUL`);
	}
	if (passwordBytes < 1 || passwordBytes > SASL_PASSWORD_BYTES || credentials.password.includes("\0")) {
		throw new Error(`IRC SASL password must be 1..${SASL_PASSWORD_BYTES} UTF-8 bytes without NUL`);
	}
}

export function saslPlainPayload(credentials: SaslPlainCredentials): string {
	validateSaslPlain(credentials);
	const bytes = new TextEncoder().encode(`\0${credentials.account}\0${credentials.password}`);
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary);
}
