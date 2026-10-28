use glowcap::Session;
use std::rc::Rc;
/// Exact target, sequence, and copied argument snapshot. Submit never refreshes it.
pub struct PreparedAdd {
	session: Rc<Session>,
	target: Ref,
	arguments: Vec<Argument>,
}
impl PreparedAdd {
	pub fn submit(&self) -> Pending<Ref> {
		Pending::new(self.session.send(&self.target, "mutate", &self.arguments), capability)
	}
}
/// Copies text before acquiring a sequence. The prepared request owns that
/// snapshot until it is dropped, so caller edits cannot change submission or replay.
pub fn prepare_add(
	session: Rc<Session>,
	target: Ref,
	text: &str,
) -> Result<impl Future<Output = Result<PreparedAdd, Error>> + use<>, Error> {
	if text.len() < MIN_TEXT_BYTES || text.len() > MAX_TEXT_BYTES {
		return Err(Error::InvalidArgument);
	}
	let snapshot = text.to_owned();
	let sequence = session.send(&target, "mutation-sequence", &[]);
	Ok(async move {
		let reply = sequence.await?;
		let number = reply.as_i64().filter(|n| *n > 0).ok_or(Error::InvalidSequence)?;
		Ok(PreparedAdd {
			session,
			target,
			arguments: vec![number.into(), ADD_VERB.into(), snapshot.into()],
		})
	})
}

/// Submit once. Use prepare_add when the caller needs to retain and replay.
pub fn add(session: Rc<Session>, target: Ref, text: &str) -> impl Future<Output = Result<Ref, Error>> + use<> {
	let preparation = prepare_add(session, target, text);
	async move { preparation?.await?.submit().await }
}
