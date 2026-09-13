// Test support for what a bind address means: whether it names every interface, and whether it
// names only this machine.
//
// A listener's bind address and the address it advertises are two different
// facts. A wildcard bind accepts connections on every interface but has no
// address of its own, so nothing dialable can be derived from it and the
// caller must supply the hostname to advertise. Every rooms front asks that
// same question, so it is answered here once rather than by each of them
// comparing against a few spellings it happened to think of.
//
// The comparison is on parsed address form, not on text. `0.0.0.0` and `::`
// are the spellings people write, but `0:0:0:0:0:0:0:0` and `::0` name the
// same any-address, and a check that misses them reports a wildcard bind as
// an ordinary one.

/** Strip one surrounding bracket pair, so a bracketed IPv6 literal and its
 * bare form answer the same. */
function bareHost(host: string): string {
	const trimmed = host.trim();
	return trimmed.startsWith("[") && trimmed.endsWith("]") ? trimmed.slice(1, -1) : trimmed;
}

/** The four octets of a dotted-quad IPv4 literal, or null if it is not one. */
function ipv4Octets(bare: string): number[] | null {
	const parts = bare.split(".");
	if (parts.length !== 4) return null;
	const octets: number[] = [];
	for (const part of parts) {
		if (!/^\d{1,3}$/.test(part)) return null;
		const value = Number(part);
		if (value > 255) return null;
		octets.push(value);
	}
	return octets;
}

/** Every numeric group of an IPv6 literal, counting the empty groups a `::`
 * elides as zero and expanding an embedded IPv4 tail. Null if `bare` is not
 * an IPv6 literal. */
function ipv6Groups(bare: string): number[] | null {
	if (!bare.includes(":")) return null;
	const [address] = bare.split("%", 1); // drop any zone identifier
	const groups: number[] = [];
	for (const part of address.split(":")) {
		if (part === "") {
			groups.push(0); // an omitted run is zeros
			continue;
		}
		const embedded = ipv4Octets(part);
		if (embedded !== null) {
			groups.push((embedded[0] << 8) | embedded[1], (embedded[2] << 8) | embedded[3]);
			continue;
		}
		if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
		groups.push(Number.parseInt(part, 16));
	}
	return groups;
}

/** Whether `host` is the any-address: it binds every interface, so it names
 * no address a peer could dial and the caller must say what to advertise. */
export function isWildcardHost(host: string): boolean {
	const bare = bareHost(host).toLowerCase();
	const octets = ipv4Octets(bare);
	if (octets !== null) return octets.every((octet) => octet === 0);
	const groups = ipv6Groups(bare);
	return groups !== null && groups.every((group) => group === 0);
}

/** Whether `host` reaches only this machine. */
export function isLoopbackHost(host: string): boolean {
	const bare = bareHost(host).toLowerCase();
	if (bare === "localhost") return true;
	const octets = ipv4Octets(bare);
	if (octets !== null) return octets[0] === 127;
	const groups = ipv6Groups(bare);
	if (groups === null) return false;
	return groups.slice(0, -1).every((group) => group === 0) && groups[groups.length - 1] === 1;
}
