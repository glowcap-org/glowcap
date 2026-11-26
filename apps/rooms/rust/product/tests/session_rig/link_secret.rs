/// Recognizes a bearer link in full, encoded into a page URL, and by its
/// swissnum in wire, raw, debug, or JSON form. A failed assertion names only
/// the output that carried the secret.
pub struct LinkSecret {
	forms: Vec<Vec<u8>>,
}

impl LinkSecret {
	/// The secret of `link`, or none when `link` is not a bearer link.
	pub fn try_of(link: &str) -> Option<Self> {
		let link = link.trim();
		let parsed = glowcap::parse_sturdyref(link, glowcap::CaptpVersion::V1_0).ok()?;
		if parsed.swissnum.is_empty() {
			return None;
		}
		let listed = format!("{:?}", parsed.swissnum).into_bytes();
		let encoded = url::form_urlencoded::byte_serialize(link.as_bytes()).collect::<String>();
		let mut forms = vec![
			link.as_bytes().to_vec(),
			encoded.into_bytes(),
			parsed.swissnum.clone(),
			listed,
		];
		// The swissnum as the link writes it, which a cut-down link keeps.
		if let Some((_, tail)) = link.split_once("/s/") {
			let written = tail.split(['?', '#']).next().unwrap_or_default().as_bytes().to_vec();
			if !written.is_empty() && !forms.contains(&written) {
				forms.push(written);
			}
		}
		if let Some(Ok(escaped)) = std::str::from_utf8(&parsed.swissnum).ok().map(serde_json::to_string) {
			let escaped = escaped.trim_matches('"').as_bytes().to_vec();
			if !forms.contains(&escaped) {
				forms.push(escaped);
			}
		}
		Some(Self { forms })
	}

	#[track_caller]
	pub fn of(link: &str) -> Self {
		let Some(secret) = Self::try_of(link) else {
			panic!("a test's bearer link is not a sturdyref with a swissnum");
		};
		secret
	}

	/// Whether `text` holds any form of the link.
	pub fn is_in(&self, text: impl AsRef<[u8]>) -> bool {
		let text = text.as_ref();
		self.forms
			.iter()
			.any(|form| text.windows(form.len()).any(|window| window == form.as_slice()))
	}

	/// Assert that `text`, read from `place`, holds no form of the link.
	#[track_caller]
	pub fn assert_absent(&self, text: impl AsRef<[u8]>, place: &str) {
		assert!(!self.is_in(text), "a bearer link reached {place}");
	}
}
