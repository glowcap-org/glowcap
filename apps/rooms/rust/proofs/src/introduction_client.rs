use rooms_application::directory::{
	introduction::{Error, MAX_OUTSTANDING, Notices},
	registration::Id,
};
fn id(n: usize) -> Id {
	Id::parse(&format!("11111111-1111-4111-8111-{n:012x}")).unwrap()
}
pub fn run() {
	captured();
	let (alice, bob) = (id(1), id(2));
	let mut notices = Notices::<usize>::default();
	assert!(notices.notify(&alice).is_empty());
	assert_eq!(notices.wait(&alice, true, 1), Ok(None));
	let first = notices.wait(&alice, true, 1).unwrap().unwrap();
	let second = notices.wait(&alice, true, 2).unwrap().unwrap();
	assert!(notices.notify(&bob).is_empty());
	assert_eq!(notices.observe(&first, 3), Ok(false));
	assert_eq!(notices.notify(&alice), vec![3, 2]);
	assert_eq!(notices.observe(&first, 3), Ok(true));
	assert_eq!(notices.observe(&second, 2), Ok(true));
	// A duplicate notification after waking all current callers is banked.
	notices.notify(&alice);
	let fresh = notices.wait(&alice, false, 4).unwrap().unwrap();
	assert_eq!(notices.observe(&fresh, 4), Ok(false));
	assert_eq!(notices.notify(&alice), vec![4]);
	notices.cancel(&fresh);
	assert_eq!(notices.observe(&fresh, 4), Err(Error::Missing));
	// A fresh wait does not spend an old signal; another first retry can.
	assert_eq!(notices.wait(&alice, true, 5), Ok(None));
	let mut tickets = Vec::new();
	for n in 0..MAX_OUTSTANDING {
		tickets.push(notices.wait(&alice, false, n).unwrap().unwrap());
	}
	assert_eq!(notices.wait(&alice, false, 0), Err(Error::Full));
	assert_eq!(notices.notify(&alice).len(), MAX_OUTSTANDING);
	assert_eq!(notices.wait(&alice, false, 0), Err(Error::Full));
	for ticket in tickets {
		notices.cancel(&ticket);
	}
	let mut bank = Notices::<usize>::default();
	for n in 0..=MAX_OUTSTANDING {
		bank.notify(&id(n));
	}
	let evicted = bank.wait(&id(0), true, 0).unwrap().unwrap();
	assert_eq!(bank.wait(&id(MAX_OUTSTANDING), true, 0), Ok(None));
	bank.cancel(&evicted);
	// Directory owners never share their registration-ID banks.
	let mut other = Notices::<usize>::default();
	let foreign = other.wait(&alice, true, 0).unwrap().unwrap();
	assert_eq!(bank.observe(&foreign, 0), Err(Error::Missing));
	bank.cancel(&foreign);
	assert_eq!(other.observe(&foreign, 0), Ok(false));
}

fn captured() {
	use rooms_application::directory::introduction::Retries;
	let rows: serde_json::Value = serde_json::from_str(include_str!("../fixtures/introduction-client.json")).unwrap();
	for row in rows.as_array().unwrap() {
		let mut notices = Notices::<()>::default();
		let mut retries = Retries::default();
		let mut waiting = None;
		let mut attempts = 0;
		let mut result = None;
		let registration = Id::parse("11111111-1111-4111-8111-111111111111").unwrap();
		for step in row["trace"].as_array().unwrap() {
			match step["kind"].as_str().unwrap() {
				"notify" => {
					notices.notify(&Id::parse(step["id"].as_str().unwrap()).unwrap());
					if let Some(ticket) = waiting.as_ref()
						&& notices.observe(ticket, ()).unwrap()
					{
						waiting = None;
					}
				}
				"call" => {
					assert!(waiting.is_none());
					assert!(result.is_none());
					assert_eq!(step["verb"], "introduce");
					assert_eq!(step["args"][0], "bob");
					assert_eq!(step["args"][1], registration.as_str());
					attempts += 1;
				}
				"pending" => match retries.next_wait() {
					Some(banked) => waiting = notices.wait(&registration, banked, ()).unwrap(),
					None => result = Some("introduction-pending"),
				},
				"capability" => result = Some("capability"),
				"offline" => result = Some("peer-offline"),
				"malformed" => result = Some("malformed"),
				_ => panic!("unknown captured introduction step"),
			}
		}
		assert_eq!(result, row["result"].as_str());
		assert_eq!(attempts, row["attempts"].as_u64().unwrap());
	}
}
