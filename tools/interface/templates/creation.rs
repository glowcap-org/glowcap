/// Copies text before acquiring a sequence. The prepared request owns that
/// snapshot until it is dropped, so caller edits cannot change submission or replay.
pub fn prepare_add(
	session: Rc<Session>,
	target: Ref,
	text: &str,
) -> Result<impl Future<Output = Result<PreparedMutation<Ref>, Error>> + use<>, Error> {
	if text.len() < MIN_TEXT_BYTES || text.len() > MAX_TEXT_BYTES {
		return Err(Error::InvalidArgument);
	}
	let snapshot = text.to_owned();
	prepare_mutation(
		session,
		target,
		move |number| vec![number.into(), ADD_VERB.into(), snapshot.into()],
		capability,
	)
}

/// Submit once. Use prepare_add when the caller needs to retain and replay.
pub fn add(session: Rc<Session>, target: Ref, text: &str) -> impl Future<Output = Result<Ref, Error>> + use<> {
	let preparation = prepare_add(session, target, text);
	async move { preparation?.await?.submit().await }
}
