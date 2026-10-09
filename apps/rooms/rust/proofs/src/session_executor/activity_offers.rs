//! Scalar offers acquire the original recipe through its exact arrival source.
use super::*;
use rooms_application::{
	archive::ShareKind,
	content::session::workspace::{Invitation, InvitationAuthority, ReceivedArchive},
	fields::Text,
};
use rooms_glowcap::client::workspace::Workspace;

pub(super) async fn run(host: &Host, exporter: &Host, owner: &managed::Session<Platform>, source: &Ref, inbox: &Ref) {
	let workspace = Workspace::local(host.clone(), Platform::default(), source.clone());
	let original = workspace.snapshot().await.unwrap();
	let terms = rooms_glowcap::policy::descriptor()
		.unwrap()
		.value_for_kind(
			session::KIND,
			&session::SUPPORTED
				.iter()
				.filter(|permission| **permission != rooms_application::content::permissions::Permission::ShareCustody)
				.map(|permission| permission.key())
				.collect::<Vec<_>>(),
			&[],
		)
		.unwrap();
	let (other, _) = owner.derive(terms, 0, ControlPowers::default()).await.unwrap();
	let other = Workspace::local(host.clone(), Platform::default(), other);
	let locator = glowcap::Locator::bare("tcp", "127.0.0.1:9147");
	exporter
		.publish("offered-archive", || {
			Box::new(|verb, _| {
				assert_eq!(verb, "read");
				Ok(Argument::Void)
			})
		})
		.unwrap();
	exporter
		.publish("offered-room", || Box::new(|_, _| Ok(Argument::Void)))
		.unwrap();
	for (index, (archive, hand, publication)) in [
		(true, false, "offered-archive"),
		(false, false, "offered-room"),
		(false, true, "offered-room"),
	]
	.into_iter()
	.enumerate()
	{
		let cursor = owner.activity().token(owner.activity().cursor()).unwrap();
		let uri = glowcap::format_sturdyref(&locator, publication.as_bytes(), glowcap::CaptpVersion::V1_0).unwrap();
		if archive {
			exporter
				.send(
					inbox,
					rooms_application::direct::OFFER_ARCHIVE,
					&[
						"directory".into(),
						"direct".into(),
						"direct".into(),
						uri.as_str().into(),
					],
				)
				.await
				.unwrap();
		} else if hand {
			let room = exporter.spawn(|_, _| Ok(Argument::Void)).unwrap();
			exporter
				.send(
					inbox,
					rooms_application::direct::HAND_ROOM,
					&["garden".into(), room.into()],
				)
				.await
				.unwrap();
		} else {
			exporter
				.send(
					inbox,
					rooms_application::direct::OFFER_ROOM,
					&["garden".into(), uri.as_str().into()],
				)
				.await
				.unwrap();
		}
		let reader = workspace.activity_reader().await.unwrap();
		let event: serde_json::Value = serde_json::from_str(&reader.read(&cursor, false).await.unwrap()).unwrap();
		let token = event["cursor"].as_str().unwrap();
		let destination = requests::coordinate(
			if archive {
				custody::Role::ArchiveAccess
			} else {
				custody::Role::RoomAccess
			},
			96 + index as u64 * 2,
		);
		let origin = requests::coordinate(custody::Role::SessionAccess, 97 + index as u64 * 2);
		assert_eq!(event["incoming"], if archive { "archiveAccess" } else { "roomAccess" });
		assert!(
			!event["data"].as_str().unwrap().contains(&uri),
			"presentation carries no bearer recipe"
		);
		let mut intent = original.intent.clone();
		if archive {
			intent.archive_shares = List::new(vec![ReceivedArchive {
				id: Text::new("durable-arrival".into()).unwrap(),
				channel: intent.conversations.as_slice()[0].id().clone(),
				directory: Text::new("directory".into()).unwrap(),
				kind: ShareKind::Direct,
				conversation: Some(Text::new("direct".into()).unwrap()),
				from: Text::new("peer".into()).unwrap(),
				access: custody::FieldKey::new(destination.key.slot(), destination.key.generation()),
				source: custody::FieldKey::new(origin.key.slot(), origin.key.generation()),
				durable: true,
			}])
			.unwrap();
		} else {
			intent.invitations = List::new(vec![Invitation {
				id: Text::new("room-arrival".into()).unwrap(),
				directory: Text::new("directory".into()).unwrap(),
				authority: InvitationAuthority::RoomAccess(custody::FieldKey::new(
					destination.key.slot(),
					destination.key.generation(),
				)),
				source: Some(custody::FieldKey::new(origin.key.slot(), origin.key.generation())),
				label: Text::new("garden".into()).unwrap(),
				from: Text::new("peer".into()).unwrap(),
			}])
			.unwrap();
		}
		let wrong = requests::coordinate(custody::Role::ArchiveControl, 96);
		assert!(
			workspace
				.prepare_activity_acquisition(
					token,
					wrong,
					Some(origin),
					workspace.snapshot().await.unwrap().revision,
					&[],
					&intent
				)
				.await
				.unwrap()
				.submit()
				.await
				.is_err()
		);
		assert!(
			other
				.prepare_activity_acquisition(
					token,
					destination,
					Some(origin),
					workspace.snapshot().await.unwrap().revision,
					&[],
					&intent
				)
				.await
				.is_err(),
			"a sibling source cannot acquire the arrival recipe"
		);
		let acquisition = workspace
			.prepare_activity_acquisition(
				token,
				destination,
				Some(origin),
				workspace.snapshot().await.unwrap().revision,
				&[],
				&intent,
			)
			.await
			.unwrap();
		acquisition.submit().await.unwrap_or_else(|error| {
			panic!(
				"incoming acquisition (archive={archive}, hand={hand}): {error:?}; {:?}",
				host.take_failures()
			)
		});
		acquisition.submit().await.unwrap();
		if hand {
			assert_eq!(
				workspace.custody_recipe(destination).await.unwrap(),
				None,
				"handed live custody has no durable recipe"
			);
		} else {
			assert_eq!(
				workspace.custody_recipe(destination).await.unwrap().as_deref(),
				Some(uri.as_str())
			);
		}
		assert!(
			other.custody_recipe(destination).await.is_err(),
			"recipe disclosure needs ShareCustody"
		);
		assert!(
			workspace
				.custody_recipe(requests::coordinate(custody::Role::SessionAccess, 98))
				.await
				.is_err(),
			"unselected private fields have no public recipe"
		);
		assert!(
			workspace
				.custody_recipe(requests::coordinate(custody::Role::DirectAccess, 96))
				.await
				.is_err(),
			"live fields cannot disclose durable recipes"
		);
		let wrong_generation = custody::Coordinate {
			role: destination.role,
			key: custody::FieldKey::new(
				destination.key.slot(),
				NonZeroU64::new(destination.key.generation().get() + 1).unwrap(),
			),
		};
		assert!(
			workspace.custody_recipe(wrong_generation).await.is_err(),
			"a slot cannot disclose another generation"
		);
		assert!(
			workspace.custody_recipe(wrong).await.is_err(),
			"the same key under another role is not selected authority"
		);
		if archive {
			let retained = workspace.archive_reader(destination, false).await.unwrap();
			host.send(&retained, "read", &[]).await.unwrap();
		}
		owner.replace_workspace(&original.intent).await.unwrap();
		assert!(
			workspace.custody_recipe(destination).await.is_err(),
			"retained but unselected custody has no public recipe"
		);
	}
	assert!(exporter.unpublish("offered-archive").unwrap());
	assert!(exporter.unpublish("offered-room").unwrap());
}
