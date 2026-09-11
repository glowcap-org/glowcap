use super::*;
use rooms_application::server::operations::operator::{self, view, Category, ReferenceKind};

impl<D: Deadline> Session<D> {
	pub async fn operations_snapshot(
		&self,
		scope: &str,
		capability: rooms_application::session::operations::Capability,
	) -> Result<rooms_application::session::operations::Snapshot, Error> {
		let mut args = scope_query(scope, "")?;
		args.push(capability.name().into());
		let reply = self.call(verbs::OPERATIONS_SNAPSHOT, &args).await?;
		Ok(rooms_application::session::operations::Snapshot::decode(
			capability,
			reply
				.as_str()
				.ok_or(Error::Reply("Rooms session returned no operations snapshot"))?,
		)?)
	}
	pub async fn operator_snapshot(
		&self,
		scope: &str,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<view::Snapshot, Error> {
		let mut args = scope_query(scope, query)?;
		args.push(query.into());
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		let reply = self.call(verbs::OPERATOR_SNAPSHOT, &args).await?;
		Ok(view::Snapshot::decode(
			reply
				.as_str()
				.ok_or(Error::Reply("Rooms session returned no operator snapshot"))?,
		)?)
	}
	pub async fn operator_page(
		&self,
		scope: &str,
		category: Category,
		cursor: u64,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<view::Page, Error> {
		let mut args = scope_query(scope, query)?;
		if rooms_application::fields::SafeInteger::<false>::new(cursor).is_none() {
			return Err(view::Refusal::Number.into());
		}
		category_kind(category, kind)?;
		args.extend([category.name().into(), Argument::Integer(cursor as i64), query.into()]);
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		Ok(view::read_page(
			category,
			&Value(&self.call(verbs::OPERATOR_PAGE, &args).await?),
		)?)
	}
	pub async fn operator_retire(
		&self,
		scope: &str,
		category: Category,
		query: &str,
		limit: u64,
		kind: Option<ReferenceKind>,
	) -> Result<view::RetireBatch, Error> {
		self.operator_retire_at(scope, category, query, limit, kind, None).await
	}
	pub async fn operator_retire_at(
		&self,
		scope: &str,
		category: Category,
		query: &str,
		limit: u64,
		kind: Option<ReferenceKind>,
		base: Option<u64>,
	) -> Result<view::RetireBatch, Error> {
		let mut args = scope_query(scope, query)?;
		if !(1..=operator::MAX_RETIRE_BATCH).contains(&limit) {
			return Err(view::Refusal::Number.into());
		}
		category_kind(category, kind)?;
		args.extend([category.name().into(), query.into(), Argument::Integer(limit as i64)]);
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		if let Some(base) = base {
			let base = rooms_application::fields::SafeInteger::<false>::new(base).ok_or(view::Refusal::Number)?;
			args.push(Argument::Integer(base.get() as i64));
		}
		Ok(view::read_retire(&Value(
			&self.call(verbs::OPERATOR_RETIRE, &args).await?,
		))?)
	}
}
fn scope_query(scope: &str, query: &str) -> Result<Vec<Argument>, Error> {
	view::validate_query(scope, query)?;
	let mut args = Vec::with_capacity(5);
	args.push(scope.into());
	Ok(args)
}
fn category_kind(category: Category, kind: Option<ReferenceKind>) -> Result<(), Error> {
	if kind.is_some() && category != Category::References {
		return Err(view::Refusal::Kind.into());
	}
	Ok(())
}
