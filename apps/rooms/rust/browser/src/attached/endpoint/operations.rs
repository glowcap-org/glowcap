use super::*;
use rooms_application::{
	server::operations::operator::{Category, ReferenceKind, view},
	session::operations,
};
impl Endpoint {
	pub async fn operations_snapshot(
		&self,
		scope: &str,
		capability: operations::Capability,
	) -> Result<operations::Snapshot> {
		match self {
			Self::Remote(s) => s.operations_snapshot(scope, capability).await.map_err(error),
			Self::Local(s, _) => s
				.operations(scope, capability)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn operator_snapshot(
		&self,
		scope: &str,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<view::Snapshot> {
		match self {
			Self::Remote(s) => s.operator_snapshot(scope, query, kind).await.map_err(error),
			Self::Local(s, _) => s
				.operator_snapshot(scope, query, kind)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn operator_page(
		&self,
		scope: &str,
		category: Category,
		cursor: u64,
		query: &str,
		kind: Option<ReferenceKind>,
	) -> Result<view::Page> {
		match self {
			Self::Remote(s) => s
				.operator_page(scope, category, cursor, query, kind)
				.await
				.map_err(error),
			Self::Local(s, _) => s
				.operator_page(scope, category, cursor, query, kind)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
	pub async fn operator_retire(
		&self,
		scope: &str,
		category: Category,
		query: &str,
		limit: u64,
		kind: Option<ReferenceKind>,
	) -> Result<view::RetireBatch> {
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
	) -> Result<view::RetireBatch> {
		match self {
			Self::Remote(s) => s
				.operator_retire_at(scope, category, query, limit, kind, base)
				.await
				.map_err(error),
			Self::Local(s, _) => s
				.operator_retire_at(scope, category, query, limit, kind, base)
				.map_err(error)?
				.wait()
				.await
				.map_err(error),
		}
	}
}
