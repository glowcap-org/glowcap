//! Reciprocal direct-request notices coalesce per peer under a bounded window.
use super::{DIRECT_REQUEST_COALESCE_MS, MAX_DM_INBOXES, Refusal};
use alloc::{collections::BTreeMap, format, string::String, vec::Vec};

pub(super) struct Due {
	pub send: bool,
	pub inserted: bool,
	pub expired: Vec<String>,
}

pub(super) fn notice_due(requests: &mut BTreeMap<String, u64>, peer: &str, now: u64) -> Result<Due, Refusal> {
	if let Some(prior) = requests.get(peer) {
		if now.saturating_sub(*prior) < DIRECT_REQUEST_COALESCE_MS {
			return Ok(Due {
				send: false,
				inserted: false,
				expired: Vec::new(),
			});
		}
	} else if requests.len() >= MAX_DM_INBOXES {
		let expired: Vec<_> = requests
			.iter()
			.filter(|(_, at)| now.saturating_sub(**at) >= DIRECT_REQUEST_COALESCE_MS)
			.map(|(peer, _)| peer.clone())
			.collect();
		for peer in &expired {
			requests.remove(peer);
		}
		if requests.len() >= MAX_DM_INBOXES {
			return Err(Refusal::plain(format!(
				"a member may track at most {MAX_DM_INBOXES} reciprocal direct requests"
			)));
		}
		requests.insert(peer.into(), now);
		return Ok(Due {
			send: true,
			inserted: true,
			expired,
		});
	}
	let inserted = requests.insert(peer.into(), now).is_none();
	Ok(Due {
		send: true,
		inserted,
		expired: Vec::new(),
	})
}
