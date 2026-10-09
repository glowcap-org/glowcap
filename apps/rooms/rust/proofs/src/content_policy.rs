//! The Rooms dependency projection reaches the shared Zig constructor on both hosts.
use rooms_application::content::permissions::Permission;
use rooms_application::content::session;

pub fn run() {
	let policy = rooms_glowcap::policy::descriptor().unwrap();
	let supported: Vec<_> = session::SUPPORTED.iter().map(|permission| permission.key()).collect();
	policy.value_for_kind(session::KIND, &supported, &[]).unwrap();
	assert!(
		policy
			.value_for_kind(session::KIND, &[Permission::ReadContent.key()], &[])
			.is_err()
	);
	assert!(policy.value_for_kind(session::KIND + 1, &supported, &[]).is_err());
	for &permission in Permission::ALL {
		if permission.prerequisite().is_some() {
			assert!(policy.value(&[permission.key()], &[]).is_err());
		} else {
			assert!(policy.value(&[permission.key()], &[]).is_ok());
		}
	}
	assert!(
		policy
			.value(&[Permission::Receive.key(), Permission::Upload.key()], &[])
			.is_err()
	);
	policy
		.value(
			&[
				Permission::Receive.key(),
				Permission::Post.key(),
				Permission::Upload.key(),
			],
			&[],
		)
		.unwrap();
	let keys: Vec<_> = Permission::ALL.iter().map(|permission| permission.key()).collect();
	policy.value(&keys, &[]).unwrap();
}
