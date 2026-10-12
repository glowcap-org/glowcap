//! Bridge credential recovery uses private Loam witnesses and separate storage.
mod admission;
pub(super) mod credentials;
pub(super) mod pipeline;
pub(super) mod retention;
use super::*;
pub(super) use admission::{admit, reapplication, references, request};
use credentials::Witness;
use glowcap::Argument;
use rooms_application::text::DocumentText;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
	owner: DocumentText,
	witnesses: Vec<Witness>,
}
/// At most 64 scalar recovery witnesses (under 8 KiB), rather than 64 form
/// declarations. One temporary spine and encoded reply cross the private Host
/// call. Neither capability restoration nor a serde Value tree is needed.
pub(super) fn credential_snapshot(
	owner: &[u8; 16],
	witnesses: &[rooms_application::content::session::bridge::Witness],
) -> Result<Argument> {
	#[derive(serde::Serialize)]
	struct Snapshot<'a> {
		owner: String,
		witnesses: &'a [Witness],
	}
	let witnesses: Vec<_> = witnesses
		.iter()
		.map(|witness| Witness {
			id: witness.id,
			credentials: witness.credentials.clone(),
		})
		.collect();
	serde_json::to_string(&Snapshot {
		owner: rooms_application::fields::lower_hex(owner),
		witnesses: &witnesses,
	})
	.map(Into::into)
	.map_err(|_| glowcap::loam::refusal("invalid bridge recovery witnesses"))
}
impl<P: Tasks + Deadline + Clone + 'static> Session<P> {
	/// Startup installs the independent credential journal before admitting
	/// bridge requests. Its namespace comes from the actual selected Loam owner.
	/// Neither tab labels, room names nor imported workspace intent bind secrets.
	pub async fn configure_credentials<D: crate::documents::Document + 'static>(&self, document: D) -> Result<()> {
		if self.state.credentials.borrow().is_some() {
			return Err(glowcap::loam::refusal("bridge credentials are already owned"));
		}
		let raw = self.state.writer.idempotent("bridge-witnesses", &[]).await?;
		let snapshot: Snapshot = serde_json::from_str(
			raw.as_str()
				.ok_or_else(|| glowcap::loam::refusal("invalid private bridge witnesses"))?,
		)
		.map_err(|_| glowcap::loam::refusal("invalid private bridge witnesses"))?;
		let credentials = credentials::Credentials::open(snapshot.owner, document).await?;
		credentials.recover(&snapshot.witnesses).await?;
		if self.state.credentials.borrow().is_some() {
			return Err(glowcap::loam::refusal("bridge credential startup overlapped"));
		}
		let credentials = Rc::new(credentials);
		let retention = retention::Owner::start(self, credentials.clone())?;
		*self.state.credentials.borrow_mut() = Some(credentials);
		*self.state.credential_retention.borrow_mut() = Some(Rc::new(retention));
		Ok(())
	}
}

pub(super) fn forget<P: Tasks + Deadline + Clone + 'static>(
	owner: &State<P>,
	call: &mut glowcap::loam::Call<'_>,
	input: glowcap::loam::Invocation<'_>,
) -> Result<Argument> {
	use rooms_application::content::session::bridge;
	let [base, room] = input.args else {
		return Err(glowcap::loam::refusal("forget-bridge takes revision and room"));
	};
	if base.as_i64().and_then(|base| u64::try_from(base).ok()) != Some(input.content_revision) {
		return Err(glowcap::loam::refusal("workspace revision changed"));
	}
	let room = content::text(room)?;
	let mut record = records::decode(input)?;
	if record.effects.as_slice().iter().any(|receipt| {
		owner
			.jobs
			.borrow()
			.contains_key(receipt.operation.text().as_str().unwrap_or(""))
			&& bridge::Request::read(receipt.canonical_intent.text().as_str().unwrap_or(""))
				.is_ok_and(|request| request.room.text().as_str() == Some(room))
	}) {
		return Err(glowcap::loam::refusal(
			"original bridge operation must finish before forgetting",
		));
	}
	bridge::forget(&mut record, room);
	records::replace(call, input, &mut record)?;
	Ok(Argument::Void)
}
