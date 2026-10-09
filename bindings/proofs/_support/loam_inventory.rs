//! Shared wire management journey on native LMDB and browser IndexedDB.
use super::{Argument, ControlPowers, Policy, Ref, Session};

async fn revision(session: &Session, control: &Ref) -> u64 {
	super::management::revision(session, control).await
}
fn page(reply: &Argument) -> (&[Argument], &Argument) {
	let Argument::Tagged { tag, value } = reply else {
		panic!("inventory result")
	};
	assert_eq!(tag, "access:inventory");
	(value[0].as_list().unwrap(), &value[1])
}

pub async fn exercise(session: &Session, control: &Ref, policy: &Policy) -> String {
	let wide = policy.value(&[10, 20], &[]).unwrap();
	let powers = ControlPowers {
		inspect: true,
		issue_ceiling: Some(wide),
		policy_ceiling: Some(wide),
		delegate_control: true,
		pause: true,
		resume: true,
		revoke: true,
	};
	let request =
		wide.with_ceiling(wide)
			.issue_arguments(1, revision(session, control).await, 0, powers, "terminal", false);
	let issued = session.send(control, "issue-access", &request).await.unwrap();
	let pair = issued.as_list().unwrap();
	let source = Ref::try_from(&pair[0]).unwrap();
	let administration = Ref::try_from(&pair[1]).unwrap();
	assert!(
		session
			.send(&source, "derive", &wide.derive_arguments(1, 0))
			.await
			.is_err()
	);
	let pause = vec![Argument::Bytes(
		revision(session, &administration).await.to_be_bytes().to_vec(),
	)];
	session.send(&administration, "pause", &pause).await.unwrap();
	let child_request = wide.with_ceiling(wide).issue_arguments(
		1,
		revision(session, &administration).await,
		0,
		ControlPowers::default(),
		"while paused",
		false,
	);
	let child = session
		.send(&administration, "issue-access", &child_request)
		.await
		.unwrap();
	let child = Ref::try_from(&child.as_list().unwrap()[0]).unwrap();
	assert!(session.send(&child, "get", &[]).await.is_err());
	let inventory = session
		.send(&administration, "inventory", &[Argument::Void, 1.into()])
		.await
		.unwrap();
	let (rows, cursor) = page(&inventory);
	assert_eq!(rows.len(), 1);
	let Argument::Tagged { value, .. } = &rows[0] else {
		panic!("grant row")
	};
	assert_eq!(value[3].as_str(), Some("while paused"));
	assert_eq!(value[5], Argument::Symbol("paused".into()));
	let old_revision = revision(session, &administration).await;
	let label = ControlPowers::label_arguments(1, old_revision, "renamed terminal");
	session.send(&administration, "mutate", &label).await.unwrap();
	assert!(
		session.send(&administration, "mutate", &label).await.is_ok(),
		"exact replay precedes stale revision admission"
	);
	assert!(
		session
			.send(
				&administration,
				"mutate",
				&ControlPowers::label_arguments(2, old_revision, "renamed terminal")
			)
			.await
			.is_err(),
		"no-op labels still check expected revision"
	);
	assert!(
		session
			.send(&administration, "inventory", &[cursor.clone(), 1.into()])
			.await
			.is_err(),
		"editing invalidates the cursor"
	);
	let replay = session
		.send(&administration, "issue-access", &child_request)
		.await
		.unwrap();
	assert_eq!(
		Ref::try_from(&replay.as_list().unwrap()[0]).unwrap(),
		child,
		"issuance replay retains exact identity before checking the old revision"
	);
	let resume = vec![Argument::Bytes(
		revision(session, &administration).await.to_be_bytes().to_vec(),
	)];
	session.send(&administration, "resume", &resume).await.unwrap();
	assert!(session.send(&child, "get", &[]).await.is_ok());
	let sequence = session
		.send(&administration, "mutation-sequence", &[])
		.await
		.unwrap()
		.as_i64()
		.unwrap() as u32;
	let inspector = session
		.send(
			&administration,
			"mutate",
			&ControlPowers {
				inspect: true,
				..Default::default()
			}
			.attenuation_arguments(sequence),
		)
		.await
		.unwrap();
	let inspector = Ref::try_from(&inspector).unwrap();
	assert_eq!(
		page(
			&session
				.send(&inspector, "inventory", &[Argument::Void, 32.into()])
				.await
				.unwrap()
		)
		.0
		.len(),
		1
	);
	assert!(
		session
			.send(
				&inspector,
				"issue-access",
				&wide.with_ceiling(wide).issue_arguments(
					1,
					revision(session, &inspector).await,
					0,
					ControlPowers::default(),
					"forbidden",
					false
				)
			)
			.await
			.is_err()
	);
	assert!(
		session
			.send(
				&inspector,
				"mutate",
				&ControlPowers::label_arguments(1, revision(session, &inspector).await, "forbidden")
			)
			.await
			.is_err()
	);
	let swiss = session
		.send(&source, "durable-name", &[])
		.await
		.unwrap()
		.as_str()
		.unwrap()
		.to_owned();
	let expected = request[1].as_bytes().unwrap();
	format!("{}:{swiss}", u64::from_be_bytes(expected.try_into().unwrap()))
}

pub async fn reopen(session: &Session, control: &Ref, policy: &Policy, saved: &str) {
	let (expected, swiss) = saved.split_once(':').unwrap();
	let wide = policy.value(&[10, 20], &[]).unwrap();
	let powers = ControlPowers {
		inspect: true,
		issue_ceiling: Some(wide),
		policy_ceiling: Some(wide),
		delegate_control: true,
		pause: true,
		resume: true,
		revoke: true,
	};
	let issued = session
		.send(
			control,
			"issue-access",
			&wide
				.with_ceiling(wide)
				.issue_arguments(1, expected.parse().unwrap(), 0, powers, "terminal", false),
		)
		.await
		.unwrap();
	let pair = issued.as_list().unwrap();
	let source = Ref::try_from(&pair[0]).unwrap();
	let administration = Ref::try_from(&pair[1]).unwrap();
	assert_eq!(
		session.send(&source, "durable-name", &[]).await.unwrap().as_str(),
		Some(swiss)
	);
	let inventory = session
		.send(&administration, "inventory", &[Argument::Void, 32.into()])
		.await
		.unwrap();
	assert_eq!(
		page(&inventory).0.len(),
		1,
		"indexed child membership restores physically"
	);
}
