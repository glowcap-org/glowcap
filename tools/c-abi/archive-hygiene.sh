#!/bin/sh
# Shared shell-port archive listing validation (ADR-0077).
#
# `archive_hygiene_check TARBALL PREFIX` validates only PREFIX, matching the
# binding extractors. An empty PREFIX validates the whole archive, for callers
# such as release-pack that extract every member.
#
# Returns:
#   0 clean
#   1 unsafe member or an unrecognized verbose-listing format (message on stdout)
#   2 tar listing failed

archive_hygiene_check_compressed() {
	tarball=$1
	prefix=$2
	compression=$3
	case "$compression" in
	z | j | J) ;;
	*)
		printf '%s\n' "unsupported tar compression selector: $compression"
		return 2
		;;
	esac

	# `TAR_OPTIONS` is cleared here and at the extract call site: validating
	# under one set of tar flags and extracting under another checks nothing.
	# `--numeric-owner` is half of the defence below. Without it the owner and
	# group columns are attacker-chosen *text*, and text with spaces in it
	# splits into extra fields — which moves where the member name begins.
	listing=$(LC_ALL=C TAR_OPTIONS= tar --numeric-owner "-tv${compression}f" "$tarball") || return 2
	# Parse the complete listing in one awk process. The old shell loop spawned
	# `cut` plus `awk` for every member, turning a checked upstream source archive
	# into minutes of process churn. The grammar and refusal policy are unchanged.
	if ! violation=$(printf '%s\n' "$listing" | awk -v prefix="$prefix" '
		function digits(s) { return s ~ /^[0-9]+$/ }
		function iso_date(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
		function month(s) { return s ~ /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$/ }
		function clock_or_year(s) { return s ~ /^([0-9][0-9]:[0-9][0-9](:[0-9][0-9])?|[0-9][0-9][0-9][0-9])$/ }
		function fail(message) { print message; failed = 1; exit 1 }
		NF {
			kind = substr($1, 1, 1)
			if (NF >= 6 && $2 ~ /^[0-9]+\/[0-9]+$/ && digits($3) && iso_date($4) && clock_or_year($5)) {
				start = 6
			} else if (NF >= 9 && digits($2) && digits($3) && digits($4) && digits($5) && month($6) &&
			           digits($7) && clock_or_year($8)) {
				start = 9
			} else {
				fail("unrecognized tar listing format (need GNU or BSD tar; got: " $0 ")")
			}
			name = $start
			for (i = start + 1; i <= NF; i++) name = name " " $i
			if (substr(name, 1, 2) == "./") name = substr(name, 3)
			if (kind == "l") sub(/ -> .*/, "", name)
			if (kind == "h") sub(/ link to .*/, "", name)
			if (prefix != "" && name != prefix && index(name, prefix "/") != 1) next
			if (kind != "-" && kind != "d") fail("refusing non-file tar member: " name)
			if (substr(name, 1, 1) == "/" || name ~ /(^|\/)\.\.($|\/)/)
				fail("refusing unsafe tar member: " name)
		}
		END {
			if (!failed) exit 0
		}
	'); then
		printf '%s\n' "$violation"
		case "$violation" in
		unrecognized\ tar\ listing\ format*)
			printf '%s\n' "  the validator refuses a listing it cannot parse rather than guess (ADR-0077 section 5)"
			printf '%s\n' "  install GNU tar, or set GLOWCAP_LIB_DIR to a directory you extracted yourself"
			;;
		esac
		return 1
	fi
	# Explicit, not the read loop's last status: a trailing command added here
	# later would otherwise decide the verdict, and the caller reads any
	# non-zero as a refusal with an empty message.
	return 0
}

archive_hygiene_check() {
	archive_hygiene_check_compressed "$1" "$2" z
}
