use std::rc::Rc;

/// Exact target, sequence, and owned arguments, retained for submission and replay.
pub struct PreparedMutation<T> {
	session: Rc<Session>,
	target: Ref,
	arguments: Vec<Argument>,
	decode: fn(Argument) -> Result<T, Error>,
}
impl<T> PreparedMutation<T> {
	pub fn submit(&self) -> Pending<T> {
		Pending::new(self.session.send(&self.target, "mutate", &self.arguments), self.decode)
	}
}

// Snapshots live inline in the future until acquisition succeeds. Cancellation
// releases them without allocating the request vector or copying its wire verb.
// A successful preparation owns one vector through submission and replay.
fn prepare_mutation<T, Arguments>(
	session: Rc<Session>,
	target: Ref,
	make_arguments: Arguments,
	decode: fn(Argument) -> Result<T, Error>,
) -> Result<impl Future<Output = Result<PreparedMutation<T>, Error>> + use<T, Arguments>, Error>
where
	Arguments: FnOnce(i64) -> Vec<Argument>,
{
	let target = target.retain_for(&session.host())?;
	let sequence = session.send(&target, "mutation-sequence", &[]).with_owned_outcome();
	Ok(async move {
		let reply = sequence.await?;
		let number = reply.as_i64().filter(|n| *n > 0).ok_or(Error::InvalidSequence)?;
		Ok(PreparedMutation {
			session,
			target,
			arguments: make_arguments(number),
			decode,
		})
	})
}
