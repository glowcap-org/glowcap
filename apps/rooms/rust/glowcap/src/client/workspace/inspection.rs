//! Readers preserve exact session admission while forwarding bounded operations
//! descriptions. A publication query reads Loam's actual saved recipe.
use super::*;
use rooms_application::{
	server::operations::operator::{Category, ReferenceKind, view},
	session::operations::{self, mutation::Kind},
};

impl<D: Deadline + Clone> Workspace<D> {
	/// Inspect the exact live leases selected by this workspace. The peering
	/// issuer cannot enumerate someone else's publications on our behalf.
	pub async fn peering_snapshot(&self) -> Result<operations::Snapshot, Error> {
		let selected = self.snapshot().await?.intent.peering;
		let mut rows = Vec::with_capacity(selected.as_slice().len());
		for row in selected.as_slice() {
			let coordinate = custody::Coordinate {
				role: custody::Role::PublicationLease,
				key: custody::FieldKey::new(row.lease.slot(), row.lease.generation()),
			};
			let reader = self.operations_reader(coordinate, Some(Kind::Peering)).await?;
			let phase = reader.publication_phase().await?;
			rows.push(serde_json::json!({"id":row.id,"name":row.name,"source":row.directory,"phase":phase}));
		}
		if self.snapshot().await?.intent.peering != selected {
			return Err(loam::refusal("publication lease selection changed during inspection").into());
		}
		operations::Snapshot::decode(
			operations::Capability::Peering,
			&serde_json::to_string(&rows).map_err(|_| loam::refusal("invalid publication snapshot"))?,
		)
		.map_err(|error| loam::refusal(error.to_string()).into())
	}
	pub async fn trace_snapshot(&self, selected: custody::Coordinate) -> Result<operations::Snapshot, Error> {
		let value = self
			.call("trace-snapshot", &[coordinate_text(selected)?.into(), "trace".into()])
			.await?;
		operations::Snapshot::decode(
			operations::Capability::Trace,
			value.as_str().ok_or_else(|| loam::refusal("invalid trace snapshot"))?,
		)
		.map_err(|error| loam::refusal(error.to_string()).into())
	}
	pub async fn issued_archive_shares(&self) -> Result<Vec<super::super::archive::ShareView>, Error> {
		let reference = self.call("archive-issuer-reader", &[]).await?;
		if matches!(reference, Argument::Void) {
			return Ok(Vec::new());
		}
		let reference = Ref::try_from(&reference).map_err(|_| loam::refusal("invalid archive issuer reader"))?;
		super::super::archive::Archive::through(self.caller.clone(), reference)
			.shares()
			.await
	}
	pub async fn custody_recipe(&self, coordinate: custody::Coordinate) -> Result<Option<String>, Error> {
		match self
			.call("custody-recipe", &[coordinate_text(coordinate)?.into()])
			.await?
		{
			Argument::Void => Ok(None),
			Argument::String(uri) => Ok(Some(uri)),
			_ => Err(loam::refusal("invalid custody recipe").into()),
		}
	}
	pub async fn operations_reader(
		&self,
		coordinate: custody::Coordinate,
		kind: Option<Kind>,
	) -> Result<OperationsReader<D>, Error> {
		let kind_value = kind
			.map(|kind| {
				serde_json::to_value(kind)
					.ok()
					.and_then(|value| value.as_str().map(str::to_owned))
					.ok_or_else(|| loam::refusal("operations kind has no text form"))
			})
			.transpose()?;
		let reference = self
			.reader(
				"operations-reader",
				&[
					coordinate_text(coordinate)?.into(),
					kind_value.map_or(Argument::Void, Into::into),
				],
			)
			.await?;
		Ok(OperationsReader {
			caller: self.caller.clone(),
			reference,
			kind,
		})
	}
}
pub struct OperationsReader<D> {
	caller: Caller<D>,
	reference: Ref,
	kind: Option<Kind>,
}
impl<D: Deadline> OperationsReader<D> {
	pub async fn publication_phase(&self) -> Result<operations::Phase, Error> {
		if self.kind != Some(Kind::Peering) {
			return Err(loam::refusal("not a publication lease reader").into());
		}
		let value = self
			.call(rooms_application::protocol_data::PUBLICATION_DESCRIBE, &[])
			.await?;
		serde_json::from_value(serde_json::Value::String(
			value
				.as_str()
				.ok_or_else(|| loam::refusal("invalid publication phase"))?
				.into(),
		))
		.map_err(|_| loam::refusal("invalid publication phase").into())
	}
	async fn call(&self, verb: &'static str, args: &[Argument]) -> Result<Argument, Error> {
		self.caller
			.call(
				&self.reference,
				verb,
				args,
				"the original operations reader did not answer",
			)
			.await
	}
	pub async fn operator_snapshot(&self, query: &str, kind: Option<ReferenceKind>) -> Result<view::Snapshot, Error> {
		view::validate_query("selected", query).map_err(|e| loam::refusal(e.to_string()))?;
		if self.kind.is_some() {
			return Err(loam::refusal("not an operator interface").into());
		}
		let mut args = vec![query.into()];
		args.extend(kind.map(|kind| kind.name().into()));
		Ok(view::read_snapshot(&crate::Value(
			&self
				.call(rooms_application::server::operations::operator::verbs::SNAPSHOT, &args)
				.await?,
		))
		.map_err(|e| loam::refusal(e.to_string()))?)
	}
	pub async fn operator_page(
		&self,
		category: Category,
		cursor: u64,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<view::Page, Error> {
		view::validate_query("selected", query).map_err(|e| loam::refusal(e.to_string()))?;
		if self.kind.is_some() || (kind.is_some() && category != Category::References) || cursor >= 1 << 53 {
			return Err(loam::refusal("invalid operator page selection").into());
		}
		let mut args = vec![
			category.name().into(),
			(cursor as i64).into(),
			32i64.into(),
			query.into(),
		];
		args.extend(kind.map(|kind| kind.name().into()));
		Ok(view::read_page(
			category,
			&crate::Value(
				&self
					.call(rooms_application::server::operations::operator::verbs::SNAPSHOT, &args)
					.await?,
			),
		)
		.map_err(|e| loam::refusal(e.to_string()))?)
	}
	pub async fn snapshot(&self) -> Result<operations::Snapshot, Error> {
		match self.kind {
			Some(Kind::Listeners) => Ok(
				operations::wire::listeners(&crate::Value(&self.call("list", &[]).await?))
					.map_err(|e| loam::refusal(e.to_string()))?,
			),
			Some(Kind::Diagnostics) => Ok(operations::wire::diagnostics(&crate::Value(
				&self.call("snapshot", &[]).await?,
			))
			.map_err(|e| loam::refusal(e.to_string()))?),
			Some(kind @ (Kind::IrcGateway | Kind::IrcConnection)) => {
				let reply = self
					.call(
						if kind == Kind::IrcGateway {
							"snapshot"
						} else {
							"describe"
						},
						&[],
					)
					.await?;
				let raw = reply.as_str().ok_or_else(|| loam::refusal("invalid IRC description"))?;
				Ok(operations::Snapshot::Irc(Box::new(
					rooms_application::bridge::gateway::Description::decode(raw).map_err(loam::refusal)?,
				)))
			}
			_ => Err(loam::refusal("this interface has no operations snapshot").into()),
		}
	}
}
