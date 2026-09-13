use super::super::{Steps, value};
use super::*;
use rooms_application::{
	archive::{Facet, MAX_READ, MAX_RECORDS, blobs::Reader},
	fields::SafeInteger,
};
use std::sync::Arc;
use wasm_bindgen::{JsCast, JsValue};
use web_sys::{IdbCursorWithValue, IdbKeyRange, IdbTransactionMode};
pub(super) fn page(database: &Database, filter: Filter, after: u64, limit: usize) -> Result<Operation<Page>, Error> {
	filter.validate()?;
	if SafeInteger::<false>::new(after).is_none() || limit == 0 {
		return Err(Error::Invalid("invalid archive read bounds"));
	}
	let limit = limit.min(MAX_READ);
	Operation::start(
		database,
		&[RECORDS, META],
		IdbTransactionMode::Readonly,
		Page {
			next: after,
			more: false,
			records: Vec::new(),
		},
		move |steps| {
			let requested = filter;
			steps.request(steps.store(META)?.get(&"revision".into())?, move |steps, row| {
				let latest = codec::meta(row, "revision", MAX_SAFE)?;
				let filter = requested.clone();
				let range = IdbKeyRange::lower_bound_with_open(&(after as f64).into(), true)?;
				let request = steps
					.store(RECORDS)?
					.index("revision")?
					.open_cursor_with_range(&range)?;
				let mut seen = 0;
				steps.request(request, move |steps, row| {
					if row.is_null() {
						return steps.data(|page| {
							page.next = page.next.max(latest);
							Ok(())
						});
					}
					seen += 1;
					if seen > MAX_RECORDS {
						return Err(Error::Invalid("archive storage exceeds its record ceiling"));
					}
					let cursor = row
						.dyn_into::<IdbCursorWithValue>()
						.map_err(|_| Error::Invalid("invalid archive cursor"))?;
					let entry = codec::decode(cursor.value()?)?;
					if value::natural(&cursor.key()?, MAX_SAFE)? != entry.revision || entry.revision > latest {
						return Err(Error::Invalid("inconsistent archive revision index"));
					}
					let proceed = steps.data(|page| {
						if filter.matches(&entry.record) {
							if page.records.len() == limit {
								page.more = true;
								return Ok(false);
							}
							if entry.revision <= page.next {
								return Err(Error::Invalid("archive revisions are not ordered"));
							}
							page.next = entry.revision;
							page.records.push(Arc::new(entry));
						}
						Ok(true)
					})?;
					if proceed {
						cursor.continue_()?;
					}
					Ok(())
				})
			})
		},
	)
}
pub(in crate::storage) fn reader(
	database: &Database,
	facet: Facet,
	digest: String,
) -> Result<Operation<Option<Reader>>, Error> {
	let scope = facet
		.scope()
		.intersect(&Filter {
			digest: Some(digest.clone()),
			..Default::default()
		})
		.ok_or(Error::Invalid("disjoint archive blob scope"))?;
	scope.validate()?;
	Operation::start(database, &[RECORDS], IdbTransactionMode::Readonly, None, move |steps| {
		let mut seen = 0;
		let range = IdbKeyRange::only(&digest.clone().into())?;
		steps.request(
			steps.store(RECORDS)?.index("digest")?.open_cursor_with_range(&range)?,
			move |steps: &Steps<Option<Reader>>, row: JsValue| {
				if row.is_null() {
					return Ok(());
				}
				seen += 1;
				if seen > MAX_RECORDS {
					return Err(Error::Invalid("archive storage exceeds its record ceiling"));
				}
				let cursor = row
					.dyn_into::<IdbCursorWithValue>()
					.map_err(|_| Error::Invalid("invalid archive cursor"))?;
				let entry = codec::decode(cursor.value()?)?;
				if cursor.key()?.as_string().as_deref() != Some(digest.as_str()) {
					return Err(Error::Invalid("inconsistent archive digest index"));
				}
				if scope.matches(&entry.record) {
					steps.data(|result| {
						*result = Some(Reader::matching(&facet, &entry.record, &digest)?);
						Ok(())
					})
				} else {
					cursor.continue_()?;
					Ok(())
				}
			},
		)
	})
}
