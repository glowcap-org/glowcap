//! Local operator actions use the same admission and typed response readers as
//! the wire facet, without encoding an intermediate JSON snapshot.
use super::*;
use glowcap::Argument;
use rooms_application::server::operations::operator::{Category, ReferenceKind, view};
use rooms_application::session::verbs;
use rooms_glowcap::Value;

impl<P: Platform> Local<P> {
	pub fn operator_snapshot(
		&self,
		scope: &str,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<Completion<view::Snapshot>, Error> {
		let facet = self.facet()?;
		let mut args = query_args(scope, query)?;
		args.push(query.into());
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		super::super::verbs::operator::prepare(&facet, verbs::OPERATOR_SNAPSHOT, &args, |reply| {
			view::read_snapshot(&Value(&reply)).map_err(Error::invalid_by)
		})?
		.start(&facet)
	}
	pub fn operator_page(
		&self,
		scope: &str,
		category: Category,
		cursor: u64,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<Completion<view::Page>, Error> {
		let facet = self.facet()?;
		let mut args = query_args(scope, query)?;
		let cursor = rooms_application::fields::SafeInteger::<false>::new(cursor)
			.ok_or_else(|| Error::invalid("operator page cursor is out of range"))?
			.get();
		args.extend([category.name().into(), Argument::Integer(cursor as i64), query.into()]);
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		super::super::verbs::operator::prepare(&facet, verbs::OPERATOR_PAGE, &args, move |reply| {
			view::read_page(category, &Value(&reply)).map_err(Error::invalid_by)
		})?
		.start(&facet)
	}
	pub fn operator_retire(
		&self,
		scope: &str,
		category: Category,
		query: &str,
		limit: u64,
		kind: Option<ReferenceKind>,
	) -> Result<Completion<view::RetireBatch>, Error> {
		self.operator_retire_at(scope, category, query, limit, kind, None)
	}
	pub fn operator_retire_at(
		&self,
		scope: &str,
		category: Category,
		query: &str,
		limit: u64,
		kind: Option<ReferenceKind>,
		base: Option<u64>,
	) -> Result<Completion<view::RetireBatch>, Error> {
		let facet = self.facet()?;
		let mut args = query_args(scope, query)?;
		let limit = i64::try_from(limit).map_err(|_| Error::invalid("operator retirement limit is out of range"))?;
		args.extend([category.name().into(), query.into(), Argument::Integer(limit)]);
		args.extend(kind.map(|kind| Argument::from(kind.name())));
		if let Some(base) = base {
			let base = rooms_application::fields::SafeInteger::<false>::new(base)
				.ok_or_else(|| Error::invalid("operator retirement revision is out of range"))?;
			args.push(Argument::Integer(base.get() as i64));
		}
		super::super::verbs::operator::prepare(&facet, verbs::OPERATOR_RETIRE, &args, |reply| {
			view::read_retire(&Value(&reply)).map_err(Error::invalid_by)
		})?
		.start(&facet)
	}
}
fn query_args(scope: &str, query: &str) -> Result<Vec<Argument>, Error> {
	view::validate_query(scope, query).map_err(Error::invalid_by)?;
	Ok(vec![scope.into()])
}
