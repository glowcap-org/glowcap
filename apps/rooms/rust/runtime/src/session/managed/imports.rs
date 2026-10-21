//! Typed ingress transfers checked custody to the shared save owner.
use super::*;
use rooms_application::content::session::workspace;
use rooms_glowcap::client::workspace::AcquisitionRequest;
pub use rooms_glowcap::client::workspace::Import;

impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// A trusted embedding supplies exact held authority. Single and bulk
	/// ingress share recipe validation and the same managed save declaration.
	pub async fn import(&self, coordinate: custody::Coordinate, reference: Ref, uri: Option<String>) -> Result<()> {
		let args = Import {
			coordinate,
			reference,
			uri,
		}
		.into_arguments()?;
		self.state.writer.idempotent("import", &args).await.map(|_| ())
	}
	/// Local and remote consumers retain the same complete acquisition envelope.
	/// The private writer only serializes invocation. Loam owns admission,
	/// revision fencing, exact retry and the atomic custody/content transaction.
	pub async fn acquire_workspace(
		&self,
		source: &Ref,
		expected: u64,
		imports: Vec<Import>,
		releases: &[custody::Coordinate],
		intent: &workspace::Intent,
	) -> Result<()> {
		let request = AcquisitionRequest::new(expected, imports, releases, intent)?;
		let reply = self
			.state
			.writer
			.idempotent_through(source, "acquire-workspace", request.arguments())
			.await?;
		AcquisitionRequest::check_outcome(reply).map_err(|error| glowcap::loam::refusal(error.to_string()))
	}
}
