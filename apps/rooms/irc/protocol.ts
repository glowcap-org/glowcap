// The IRC vocabulary shared by the channel bridge and native Rooms front.
//
// IRC is an edge protocol, never a CapTP netlayer. This module owns only its
// bounded line grammar and casemapping; it knows nothing about sockets, rooms,
// capabilities, or reconnect policy. The 512-byte ceiling includes CRLF.

export const IRC_LINE_BYTES = 512;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export interface IrcMessage {
	readonly tags: ReadonlyMap<string, string | null>;
	readonly prefix: string | null;
	readonly command: string;
	readonly params: readonly string[];
}

function unescapeTag(value: string): string {
	return value.replace(/\\([:\\rns])/g, (_whole, escaped: string) => {
		switch (escaped) {
			case ":":
				return ";";
			case "r":
				return "\r";
			case "n":
				return "\n";
			case "s":
				return " ";
			default:
				return "\\";
		}
	});
}

/** Parse one IRC payload without its CRLF. Unknown commands and tags remain
 * data; consumers decide which subset they understand. */
export function parseIrcLine(line: string): IrcMessage {
	if (line.length === 0 || /[\0\r\n]/.test(line)) throw new Error("IRC line contains a forbidden byte");
	if (encoder.encode(line).length + 2 > IRC_LINE_BYTES) throw new Error("IRC line exceeds 512 bytes");

	let rest = line;
	const tags = new Map<string, string | null>();
	if (rest.startsWith("@")) {
		const end = rest.indexOf(" ");
		if (end < 2) throw new Error("IRC tags have no command");
		for (const field of rest.slice(1, end).split(";")) {
			const at = field.indexOf("=");
			const key = at < 0 ? field : field.slice(0, at);
			if (!/^[A-Za-z0-9.+\-/]+$/.test(key)) throw new Error("IRC tag key is malformed");
			tags.set(key, at < 0 ? null : unescapeTag(field.slice(at + 1)));
		}
		rest = rest.slice(end + 1);
	}

	let prefix: string | null = null;
	if (rest.startsWith(":")) {
		const end = rest.indexOf(" ");
		if (end < 2) throw new Error("IRC prefix has no command");
		prefix = rest.slice(1, end);
		rest = rest.slice(end + 1);
	}

	const commandEnd = rest.indexOf(" ");
	const command = (commandEnd < 0 ? rest : rest.slice(0, commandEnd)).toUpperCase();
	if (!/^(?:[A-Z]+|[0-9]{3})$/.test(command)) throw new Error("IRC command is malformed");
	rest = commandEnd < 0 ? "" : rest.slice(commandEnd + 1);

	const params: string[] = [];
	while (rest.length > 0) {
		while (rest.startsWith(" ")) rest = rest.slice(1);
		if (rest.length === 0) break;
		if (rest.startsWith(":")) {
			params.push(rest.slice(1));
			break;
		}
		const end = rest.indexOf(" ");
		if (end < 0) {
			params.push(rest);
			break;
		}
		params.push(rest.slice(0, end));
		rest = rest.slice(end + 1);
	}
	if (params.length > 15) throw new Error("IRC line has more than 15 parameters");
	return { tags, prefix, command, params };
}

/** Encode one IRC line, including CRLF. A prefix is accepted for the server
 * side of the shared vocabulary; bridge writes omit it. The final parameter
 * becomes trailing when its spelling requires it. */
export function encodeIrcMessage(
	command: string,
	params: readonly string[] = [],
	prefix?: string,
): Uint8Array {
	const upper = command.toUpperCase();
	if (!/^(?:[A-Z]+|[0-9]{3})$/.test(upper)) throw new Error("IRC command is malformed");
	if (prefix !== undefined && (prefix.length === 0 || /[\0\r\n ]/.test(prefix))) {
		throw new Error("IRC prefix is malformed");
	}
	if (params.length > 15) throw new Error("IRC line has more than 15 parameters");
	const rendered = params.map((param, index) => {
		if (/[\0\r\n]/.test(param)) throw new Error("IRC parameter contains a forbidden byte");
		const last = index === params.length - 1;
		if (!last && (param.length === 0 || param.startsWith(":") || param.includes(" "))) {
			throw new Error("only the final IRC parameter may contain spaces");
		}
		return last && (param.length === 0 || param.startsWith(":") || param.includes(" ")) ? `:${param}` : param;
	});
	const line = `${prefix === undefined ? "" : `:${prefix} `}${upper}${
		rendered.length === 0 ? "" : ` ${rendered.join(" ")}`
	}\r\n`;
	const bytes = encoder.encode(line);
	if (bytes.length > IRC_LINE_BYTES) throw new Error("IRC line exceeds 512 bytes");
	return bytes;
}

/** Encode a client-to-server line. Kept as the narrow spelling used by the
 * bridge so a caller cannot accidentally claim a server prefix. */
export function encodeIrc(command: string, params: readonly string[] = []): Uint8Array {
	return encodeIrcMessage(command, params);
}

/** Yield complete IRC messages from arbitrary byte chunks while retaining only
 * one protocol-sized line. A truncated or overlong peer fails closed. */
export async function* readIrcLines(readable: ReadableStream<Uint8Array>): AsyncGenerator<IrcMessage> {
	const reader = readable.getReader();
	const line = new Uint8Array(IRC_LINE_BYTES - 1);
	let used = 0;
	try {
		while (true) {
			const { value, done } = await reader.read();
			if (done) break;
			for (const byte of value) {
				if (byte === 0x0a) {
					const payload = used > 0 && line[used - 1] === 0x0d
						? line.subarray(0, used - 1)
						: line.subarray(0, used);
					if (payload.length === 0) throw new Error("IRC sent an empty line");
					yield parseIrcLine(decoder.decode(payload));
					used = 0;
					continue;
				}
				if (used >= line.length) throw new Error("IRC line exceeds 512 bytes");
				line[used] = byte;
				used += 1;
			}
		}
		if (used !== 0) throw new Error("IRC stream ended mid-line");
	} finally {
		reader.releaseLock();
	}
}

/** RFC 1459's case-insensitive nickname/channel comparison. */
export function ircFold(value: string): string {
	return value.toLowerCase().replace(/[\[\\\]^]/g, (c) => ({ "[": "{", "]": "}", "\\": "|", "^": "~" })[c]!);
}

export function nickFromPrefix(prefix: string | null): string | null {
	if (prefix === null) return null;
	const end = prefix.search(/[!@]/);
	return end < 0 ? prefix : prefix.slice(0, end);
}

/** Strip the status prefixes a NAMES row puts in front of a nick. */
export function bareNamesNick(value: string): string {
	return value.replace(/^[~&@%+]+/, "");
}

/** The CTCP ACTION wrapping for a `/me`: one authority for the byte form,
 * so the outbound writer and the inbound translator cannot drift. */
export function ctcpAction(text: string): string {
	return `\u0001ACTION ${text}\u0001`;
}

/** The text inside a CTCP ACTION, or null when the line is ordinary. A
 * missing trailing delimiter is tolerated: some clients omit it. */
export function ctcpActionText(raw: string): string | null {
	if (!raw.startsWith("\u0001ACTION ")) return null;
	return raw.endsWith("\u0001") ? raw.slice(8, -1) : raw.slice(8);
}
