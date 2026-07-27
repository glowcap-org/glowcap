#!/bin/sh
# Shared shell-port archive listing validation (ADR-0077).
#
# `archive_hygiene_check TARBALL PREFIX` returns:
#   0 clean
#   1 unsafe member or an unrecognized verbose-listing format (message on stdout)
#   2 tar listing failed

# The whole line is parsed, including any " -> target" tail. Stripping that
# tail first would truncate a regular file whose own name contains " -> ", and
# the traversal check would then run on a prefix of the name tar actually
# extracts. Link entries need no strip: they are refused for their kind,
# whatever their name parses to.
tar_verbose_member_name() {
	printf '%s' "$1" | awk '
		function digits(s) { return s ~ /^[0-9]+$/ }
		function iso_date(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
		function month(s) { return s ~ /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/ }
		function clock_or_year(s) { return s ~ /^([0-9][0-9]:[0-9][0-9](:[0-9][0-9])?|[0-9][0-9][0-9][0-9])$/ }
		{
			# GNU tar: mode owner/group size YYYY-MM-DD HH:MM name...
			if (NF >= 6 && $2 ~ /^[0-9]+\/[0-9]+$/ && digits($3) && iso_date($4) && clock_or_year($5)) {
				start = 6
			# BSD tar: mode links owner group size Mon DD HH:MM name...
			} else if (NF >= 9 && digits($2) && digits($3) && digits($4) && digits($5) && month($6) &&
			           digits($7) && clock_or_year($8)) {
				start = 9
			} else {
				exit 2
			}
			for (i = start; i <= NF; i++)
				printf "%s%s", (i > start ? " " : ""), $i
			print ""
		}
	'
}

archive_hygiene_check() {
	tarball=$1
	prefix=$2
	prefix_slash="${prefix}/"

	# `TAR_OPTIONS` is cleared here and at the extract call site: validating
	# under one set of tar flags and extracting under another checks nothing.
	# `--numeric-owner` is half of the defence below. Without it the owner and
	# group columns are attacker-chosen *text*, and text with spaces in it
	# splits into extra fields — which moves where the member name begins.
	listing=$(LC_ALL=C TAR_OPTIONS= tar --numeric-owner -tvzf "$tarball") || return 2
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		kind=$(printf '%s' "$line" | cut -c1)
		if ! name=$(tar_verbose_member_name "$line"); then
			printf '%s\n' "unrecognized tar listing format (need GNU or BSD tar; got: $line)"
			printf '%s\n' "  the validator refuses a listing it cannot parse rather than guess (ADR-0077 section 5)"
			printf '%s\n' "  install GNU tar, or set PANCAKE_LIB_DIR to a directory you extracted yourself"
			return 1
		fi
		# `tar -czf x .` stores every member as `./lib/…`. Without this the
		# prefix test below matches nothing and the whole archive passes
		# unexamined, which is not the same as passing.
		case "$name" in
		./*) name=${name#./} ;;
		esac

		# A link's printed name carries its target, and tar spells the two kinds
		# differently: a symlink as `lib -> /etc`, a hard link as `lib link to real`.
		# Strip whichever tail belongs to this kind, and only for that kind, so a link
		# *named* the prefix is still recognized as being under it. Without this the
		# reconstructed name matches neither `lib` nor `lib/...`, the member is skipped
		# before the kind test, and a link named exactly `lib` is extracted as the
		# library directory. A regular file whose own name contains either separator
		# must keep its whole name, which is why the strip is conditioned on the kind.
		case "$kind" in
		l) name=${name%% -> *} ;;
		h) name=${name%% link to *} ;;
		esac

		case "$name" in
		"$prefix" | "$prefix_slash"*) ;;
		*) continue ;;
		esac
		case "$kind" in
		- | d) ;;
		*)
			printf '%s\n' "refusing non-file tar member: $name"
			return 1
			;;
		esac
		case "$name" in
		/* | ../* | */../* | */..)
			printf '%s\n' "refusing unsafe tar member: $name"
			return 1
			;;
		esac
	done <<EOF
$listing
EOF
	# Explicit, not the read loop's last status: a trailing command added here
	# later would otherwise decide the verdict, and the caller reads any
	# non-zero as a refusal with an empty message.
	return 0
}
