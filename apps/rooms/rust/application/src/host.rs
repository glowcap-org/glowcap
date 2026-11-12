//! How the host and port an operator names are read. A cleartext listener is
//! private only on loopback, a wildcard is a place to bind that nobody can
//! dial, and a port is decimal digits.
use core::net::IpAddr;

fn address(host: &str) -> Option<IpAddr> {
	host.trim_matches(['[', ']']).parse().ok()
}

/// Whether `host` reaches only this machine: `localhost` or a loopback
/// address, bracketed or not.
pub fn loopback(host: &str) -> bool {
	host.eq_ignore_ascii_case("localhost") || address(host).is_some_and(|address| address.is_loopback())
}

/// Whether `host` is the unspecified address, which binds every interface.
pub fn wildcard(host: &str) -> bool {
	address(host).is_some_and(|address| address.is_unspecified())
}

/// The port `value` names in decimal digits alone, so a sign or a space is
/// no port.
pub fn port(value: &str) -> Option<u16> {
	value
		.bytes()
		.all(|byte| byte.is_ascii_digit())
		.then(|| value.parse().ok())
		.flatten()
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn a_port_is_decimal_digits_within_range() {
		for (value, read) in [("0", Some(0)), ("7000", Some(7000)), ("65535", Some(65535))] {
			assert_eq!(port(value), read, "{value}");
		}
		for value in ["", "+7000", "-1", " 7000", "7000 ", "0x10", "65536"] {
			assert_eq!(port(value), None, "{value}");
		}
	}
	#[test]
	fn a_host_is_read_with_or_without_its_brackets() {
		for host in ["localhost", "LOCALHOST", "127.0.0.1", "127.12.34.56", "::1", "[::1]"] {
			assert!(loopback(host) && !wildcard(host), "{host}");
		}
		for host in ["0.0.0.0", "::", "[::]"] {
			assert!(wildcard(host) && !loopback(host), "{host}");
		}
		for host in ["192.0.2.7", "example.test", "localhost.example.test", ""] {
			assert!(!loopback(host) && !wildcard(host), "{host}");
		}
	}
}
