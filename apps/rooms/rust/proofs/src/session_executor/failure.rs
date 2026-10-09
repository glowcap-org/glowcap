//! Inject refusal around the real callback without changing production behavior.
use super::*;

/// Refuse after the actual production callback staged its receipt and worker.
/// This exercises rollback confirmation, without a production failure switch.
pub(super) struct AbortAfterAdmission {
	pub inner: Box<dyn Content>,
	pub refuse: Rc<Cell<bool>>,
	pub refuse_settlement: Rc<Cell<bool>>,
}
impl Content for AbortAfterAdmission {
	fn dependent_requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.dependent_requirement(input)
	}
	fn requirement(&self, input: Invocation<'_>) -> Result<Requirement> {
		self.inner.requirement(input)
	}
	fn references(&self, input: Invocation<'_>) -> Result<Vec<loam::ReferenceRequest>> {
		let requests = self.inner.references(input)?;
		// Every operation declares only the authority it will actually invoke.
		// Workspace replacement and local release require no upstream restoration.
		if matches!(input.verb, "replaceWorkspace" | "release") {
			assert!(requests.is_empty());
		}
		if input.verb == "command" {
			let declared: Vec<_> = rooms_glowcap::values(input.args).collect();
			let request = rooms_application::session::command::Request::parse(&declared).unwrap();
			if rooms_application::content::session::local::recognizes(request.route()) {
				assert!(requests.len() <= 1, "local admission restores only its replay source");
			} else {
				assert!(
					matches!(requests.len(), 1 | 2),
					"restore only selected targets or replay source"
				);
			}
		}
		Ok(requests)
	}
	fn invoke(&self, call: &mut Call<'_>, input: Invocation<'_>) -> Result<Argument> {
		let reply = self.inner.invoke(call, input)?;
		if (matches!(
			input.verb,
			"command" | "import-result" | "acquire-result-workspace" | "acquire-created-room"
		) && self.refuse.get())
			|| (input.verb == "settle-effect" && self.refuse_settlement.get())
		{
			return Err(loam::refusal("receipt callback refused after worker installation"));
		}
		Ok(reply)
	}
}
