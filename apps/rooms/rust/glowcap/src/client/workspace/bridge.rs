//! Bridge declarations are read through an exact held seat and workspace source.
use super::*;
use rooms_application::bridge;

impl<D: Deadline> Workspace<D> {
	/// Explicitly forget the room's saved bridge identities. The prepared request
	/// retains its original revision and receipt sequence through lost replies.
	pub async fn prepare_forget_bridge(&self, base: u64, room: &str) -> Result<Acquisition<D>, Error>
	where
		D: Clone,
	{
		let base = i64::try_from(base).map_err(|_| loam::refusal("invalid bridge revision"))?;
		if !rooms_application::fields::Text::<1024, true>::accepts_utf16(room.encode_utf16()) {
			return Err(loam::refusal("invalid room identity").into());
		}
		let sequence = self.mutation_sequence().await?;
		Ok(Acquisition::mutation(
			self.caller.clone(),
			self.reference.clone(),
			vec![
				i64::from(sequence).into(),
				"forget-bridge".into(),
				base.into(),
				room.into(),
			],
		))
	}
	pub async fn prepare_bridge_reapplication(
		&self,
		operation: &str,
		base: u64,
		room: &str,
	) -> Result<Command<D>, Error>
	where
		D: Clone,
	{
		let base = i64::try_from(base).map_err(|_| loam::refusal("invalid bridge revision"))?;
		let raw = self
			.call("bridge-reapplication", &[operation.into(), base.into(), room.into()])
			.await?;
		let request = rooms_application::content::session::bridge::Request::read(
			raw.as_str()
				.ok_or_else(|| loam::refusal("invalid bridge reapplication"))?,
		)
		.map_err(|_| loam::refusal("invalid bridge reapplication"))?;
		self.prepare_bridge(&request, &bridge::Answers::default())
	}
	/// Keep the exact public receipt and separate private argument under the
	/// existing command owner. Retries cannot select a successor seat or form.
	pub fn prepare_bridge(
		&self,
		request: &rooms_application::content::session::bridge::Request,
		secrets: &bridge::Answers,
	) -> Result<Command<D>, Error>
	where
		D: Clone,
	{
		if !request.bridge.validate() || secrets.iter().any(|(id, _)| !request.bridge.declaration.is_secret(id)) {
			return Err(loam::refusal("bridge answers differ from their declaration").into());
		}
		let canonical = request
			.canonical()
			.map_err(|_| loam::refusal("invalid bridge intent"))?;
		let operation = request
			.operation
			.text()
			.as_str()
			.ok_or_else(|| loam::refusal("invalid bridge operation"))?
			.to_owned();
		let private = secrets
			.encode()
			.map_err(|_| loam::refusal("invalid private bridge answers"))?;
		Ok(Command {
			caller: self.caller.clone(),
			source: self.reference.clone(),
			method: "submit-bridge",
			operation: operation.clone(),
			canonical: canonical.clone(),
			arguments: vec![operation.into(), canonical.into(), private.into()],
			_sources: None,
		})
	}
	/// This facade exposes only the form declaration. Submission is an effect
	/// with separate receipt and credential custody. It cannot escape this reader.
	pub async fn bridge_form_reader(&self, seat: custody::Coordinate) -> Result<Ref, Error> {
		self.reader("bridge-form-reader", &[coordinate_text(seat)?.into()])
			.await
	}
	pub async fn bridge_form(&self, seat: custody::Coordinate) -> Result<Option<bridge::Form>, Error> {
		let reader = self.bridge_form_reader(seat).await?;
		let reply = self
			.caller
			.call(&reader, bridge::ASK, &[], "the bridge form did not answer")
			.await?;
		Ok(bridge::read_form(&crate::Value(&reply))?)
	}
}
