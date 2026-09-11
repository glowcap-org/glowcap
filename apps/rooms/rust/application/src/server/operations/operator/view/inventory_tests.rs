use super::*;
use crate::fields::List;
use alloc::string::ToString;

fn inventory(total: u64) -> Inventory {
	let raw = serde_json::json!({
		"revision":"1", "stewardships":[], "links":[{"name":"first","label":"first","visibility":"listed"}],
		"registrations":[], "sessions":[], "rooms":[], "references":[], "trouble":[],
		"next":{"stewardships":null,"links":1,"registrations":null,"sessions":null,"rooms":null,"references":null,"trouble":null},
		"totals":{"stewardships":0,"links":total,"registrations":0,"sessions":0,"rooms":0,"references":0,"trouble":0}
	});
	Inventory::new(Snapshot::decode(&raw.to_string()).unwrap()).unwrap()
}
fn page(cursor: u64, count: usize, total: u64, text_size: usize) -> Page {
	Page {
		revision: Revision::new(1).unwrap(),
		next: if cursor + (count as u64) < total {
			Nullable::Value(SafeInteger::new(cursor + count as u64).unwrap())
		} else {
			Nullable::Null
		},
		total: SafeInteger::new(total).unwrap(),
		rows: PageRows::Links(
			List::new(
				(0..count)
					.map(|_| {
						Object(Link {
							name: Name::new("n".repeat(text_size).into()).unwrap(),
							label: Field::new("l".repeat(text_size).into()).unwrap(),
							visibility: Visibility::Listed,
						})
					})
					.collect(),
			)
			.unwrap(),
		),
	}
}
#[test]
fn operator_pages_preserve_revision_and_cursor_and_render_all_chunks() {
	let mut inventory = inventory(3);
	let mut changed = page(1, 2, 3, 1);
	changed.revision = Revision::new(2).unwrap();
	assert_eq!(
		inventory.append(Category::Links, 1, changed).unwrap(),
		Appended::Refresh
	);
	assert_eq!(inventory.cursor(Category::Links), Some(1));
	assert_eq!(
		inventory.append(Category::Links, 1, page(1, 2, 3, 1)).unwrap(),
		Appended::Ready
	);
	let rendered = serde_json::to_value(&inventory).unwrap();
	assert_eq!(rendered["links"].as_array().unwrap().len(), 3);
	assert!(inventory.cursor(Category::Links).is_none());
	assert!(inventory.append(Category::Links, 1, page(1, 2, 3, 1)).is_err());
}
#[test]
fn operator_page_byte_pressure_preserves_the_last_admitted_cursor() {
	let mut inventory = inventory(1400);
	for index in 0..40 {
		let cursor = 1 + index * 32;
		if inventory
			.append(Category::Links, cursor, page(cursor, 32, 1400, 4096))
			.is_err()
		{
			assert_eq!(inventory.cursor(Category::Links), Some(cursor));
			assert!(inventory.bytes <= MAX_RETAINED_BYTES);
			return;
		}
	}
	panic!("unbounded operator page retention");
}
