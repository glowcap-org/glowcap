use crate::uri::{HintValue, Locator};
use crate::{sys, Error, Result};

pub(crate) const HINT: &str = "rendezvous-relay";

pub(crate) fn from_locator(locator: &Locator) -> Result<Option<&str>> {
	let Some(value) = locator.hints.get(HINT) else {
		return Ok(None);
	};
	match value {
		HintValue::String(route) if !route.is_empty() => Ok(Some(route)),
		_ => Err(Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			"rendezvous-relay must be a non-empty string hint".to_string(),
		)),
	}
}

#[cfg(feature = "rendezvous")]
pub(crate) fn dial_url(route: &str, designator: &str) -> Result<String> {
	let mut url = url::Url::parse(route).map_err(|error| {
		Error::with_detail(
			sys::ERR_INVALID_ARGUMENT,
			format!("invalid rendezvous-relay URL: {error}"),
		)
	})?;
	url.query_pairs_mut().append_pair("rendezvous", designator);
	Ok(url.into())
}
