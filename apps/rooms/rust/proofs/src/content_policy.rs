//! The Rooms dependency projection reaches the shared Zig constructor on both hosts.
use rooms_application::content::permissions::Permission;

pub fn run() {
	let policy = rooms_glowcap::policy::descriptor().unwrap();
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
