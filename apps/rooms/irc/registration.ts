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
