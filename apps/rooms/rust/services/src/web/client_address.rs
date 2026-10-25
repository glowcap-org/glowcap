//! The address an HTTP request is charged to. The accepted socket's peer is the
//! source unless an operator lists it as a trusted proxy. Only then does the
//! rightmost untrusted `X-Forwarded-For` entry that proxy reported replace it.
use hyper::HeaderMap;
use std::net::IpAddr;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Prefix {
	address: IpAddr,
	length: u8,
}
impl Prefix {
	fn parse(entry: &str) -> Result<Self, String> {
		let bad = || format!("trusted proxy entry {entry:?} must be an IP address or a CIDR prefix");
		let (host, length) = match entry.split_once('/') {
			Some((host, length)) => (host, Some(length.parse::<u8>().map_err(|_| bad())?)),
			None => (entry, None),
		};
		let address: IpAddr = host.parse().map_err(|_| bad())?;
		let width = if address.is_ipv4() { 32 } else { 128 };
		let length = length.unwrap_or(width);
		if length > width {
			return Err(bad());
		}
		Ok(Self { address, length })
	}
	fn contains(&self, ip: IpAddr) -> bool {
		match (self.address, ip) {
			(IpAddr::V4(network), IpAddr::V4(ip)) => {
				let mask = u32::MAX.checked_shl(32 - u32::from(self.length)).unwrap_or(0);
				u32::from(network) & mask == u32::from(ip) & mask
			}
			(IpAddr::V6(network), IpAddr::V6(ip)) => {
				let mask = u128::MAX.checked_shl(128 - u32::from(self.length)).unwrap_or(0);
				u128::from(network) & mask == u128::from(ip) & mask
			}
			_ => false,
		}
	}
}

/// Proxies whose reported client address is believed. Empty trusts none.
#[derive(Clone, Debug, Default)]
pub(super) struct TrustedProxies(Vec<Prefix>);
impl TrustedProxies {
	pub fn parse(text: &str) -> Result<Self, String> {
		text.split(',')
			.map(str::trim)
			.filter(|entry| !entry.is_empty())
			.map(Prefix::parse)
			.collect::<Result<_, _>>()
			.map(Self)
	}
	pub fn contains(&self, ip: IpAddr) -> bool {
		self.0.iter().any(|prefix| prefix.contains(ip))
	}
	pub fn len(&self) -> usize {
		self.0.len()
	}
}

fn entry(text: &str) -> Option<IpAddr> {
	let text = text.trim();
	let text = text.strip_prefix('[').and_then(|t| t.strip_suffix(']')).unwrap_or(text);
	text.parse().ok()
}

/// The address to charge: `peer` unless it is trusted and reports a usable
/// client. An unusable report leaves the budget with the proxy.
pub(super) fn source_address(peer: IpAddr, headers: &HeaderMap, trusted: &TrustedProxies) -> IpAddr {
	if !trusted.contains(peer) {
		return peer;
	}
	let mut joined = String::new();
	for value in headers.get_all("x-forwarded-for") {
		let Ok(value) = value.to_str() else { return peer };
		if !joined.is_empty() {
			joined.push(',');
		}
		joined.push_str(value);
	}
	for part in joined.rsplit(',') {
		match entry(part) {
			Some(ip) if trusted.contains(ip) => {}
			Some(ip) => return ip,
			None => return peer,
		}
	}
	peer
}

#[cfg(test)]
mod tests {
	use super::*;

	fn ip(text: &str) -> IpAddr {
		text.parse().unwrap()
	}
	fn headers(lines: &[&str]) -> HeaderMap {
		let mut map = HeaderMap::new();
		for line in lines {
			map.append("x-forwarded-for", line.parse().unwrap());
		}
		map
	}
	fn trusted(text: &str) -> TrustedProxies {
		TrustedProxies::parse(text).unwrap()
	}

	#[test]
	fn untrusted_peer_ignores_a_spoofed_header() {
		let map = headers(&["203.0.113.9"]);
		assert_eq!(
			source_address(ip("198.51.100.1"), &map, &trusted("10.0.0.0/8")),
			ip("198.51.100.1")
		);
		assert_eq!(
			source_address(ip("10.0.0.1"), &map, &TrustedProxies::default()),
			ip("10.0.0.1")
		);
	}

	#[test]
	fn trusted_peer_takes_the_rightmost_untrusted_entry() {
		let map = headers(&["192.0.2.50, 203.0.113.9"]);
		assert_eq!(
			source_address(ip("10.0.0.1"), &map, &trusted("10.0.0.0/8")),
			ip("203.0.113.9")
		);
	}

	#[test]
	fn chained_trusted_proxies_are_skipped() {
		let map = headers(&["203.0.113.9, 10.0.0.7, 10.0.0.1"]);
		assert_eq!(
			source_address(ip("10.0.0.2"), &map, &trusted("10.0.0.0/8")),
			ip("203.0.113.9")
		);
	}

	#[test]
	fn an_unusable_report_leaves_the_budget_with_the_proxy() {
		let proxy = trusted("10.0.0.1");
		for lines in [
			&["203.0.113.9, not-an-address"][..],
			&[][..],
			&["10.0.0.1"][..],
			&[""][..],
		] {
			assert_eq!(source_address(ip("10.0.0.1"), &headers(lines), &proxy), ip("10.0.0.1"));
		}
	}

	#[test]
	fn bracketed_ipv6_and_repeated_header_lines_parse() {
		let map = headers(&["192.0.2.50", "[2001:db8::7]"]);
		assert_eq!(
			source_address(ip("fd00::1"), &map, &trusted("fd00::/8")),
			ip("2001:db8::7")
		);
		let map = headers(&["203.0.113.9", "10.0.0.7"]);
		assert_eq!(
			source_address(ip("10.0.0.1"), &map, &trusted("10.0.0.0/8")),
			ip("203.0.113.9")
		);
	}

	#[test]
	fn prefixes_match_by_length_and_family() {
		assert!(trusted("0.0.0.0/0").contains(ip("203.0.113.9")));
		assert!(!trusted("0.0.0.0/0").contains(ip("::1")));
		assert!(trusted("10.1.2.3/32").contains(ip("10.1.2.3")));
		assert!(!trusted("10.1.2.3/32").contains(ip("10.1.2.4")));
		assert!(trusted("::/0").contains(ip("2001:db8::1")));
		assert!(trusted("fd00::1/128").contains(ip("fd00::1")));
		assert!(!trusted("fd00::1/128").contains(ip("fd00::2")));
		assert!(trusted("fd00::/8").contains(ip("fd12::1")));
		assert!(!trusted("fd00::/8").contains(ip("fe00::1")));
		assert!(trusted("10.0.0.0/8").contains(ip("10.255.0.1")));
	}

	#[test]
	fn parse_names_a_bad_entry_and_accepts_empty_text() {
		for bad in ["10.0.0.0/33", "fd00::/129", "proxy.example", "10.0.0.1/x"] {
			let error = TrustedProxies::parse(&format!("10.0.0.1, {bad}")).unwrap_err();
			assert!(error.contains(bad), "{error}");
		}
		assert_eq!(trusted("").len(), 0);
		assert_eq!(trusted(" , ").len(), 0);
		assert_eq!(trusted("10.0.0.1, fd00::/8").len(), 2);
	}
}
