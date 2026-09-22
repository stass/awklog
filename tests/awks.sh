# awks.sh -- which awks to exercise; sourced by tests/run.sh and tests/fuzz.sh.
#
# Sets AWKS to a newline-separated list of awk commands and awks_missing to
# the names of those in the portability matrix that were not found, and
# exits 2 when SWEEP=1 and any is missing, or when none is found at all.
# Diagnostics are prefixed with $me, the name of the sourcing script.

# Which awks to exercise.  gawk is run twice: once natively, once in POSIX mode.
#
# An awk that is not installed is skipped, so that the suite still runs on a
# host with only one of them -- but it is named, because the summary line
# alone reads the same with one awk as with four, and a portability sweep
# that has quietly shrunk to one awk is no sweep at all.  SWEEP=1 makes the
# shortfall an error.
#
# BWK awk is recognised by its "awk version" banner, not by its name: on most
# Linux systems "awk" is gawk or mawk under another name, and BWK awk, where
# installed, goes by original-awk, nawk or bwk-awk.  The system awk is always
# run, being the one a user gets, and the first BWK awk found is added when
# the system awk is not it.  An explicit AWKS is a hand-picked list, which is
# not a sweep, so the two are refused together.
awks_missing=
if [ -n "${AWKS:-}" ]; then
	if [ "${SWEEP:-0}" = 1 ]; then
		echo "${me:-run.sh}: SWEEP=1 runs every awk found; unset AWKS" >&2
		exit 2
	fi
else
	bwk=
	for a in awk original-awk nawk bwk-awk; do
		command -v "$a" >/dev/null 2>&1 || continue
		case $("$a" --version 2>&1 < /dev/null) in
		"awk version "*)	bwk=$a; break ;;
		esac
	done
	[ -z "$bwk" ] && awks_missing="$awks_missing BWK-awk"
	command -v awk >/dev/null 2>&1 && AWKS="awk
"
	[ -n "$bwk" ] && [ "$bwk" != awk ] && AWKS="$AWKS$bwk
"
	for a in mawk gawk; do
		if command -v "$a" >/dev/null 2>&1; then
			AWKS="$AWKS$a
"
		else
			awks_missing="$awks_missing $a"
		fi
	done
	case $AWKS in
	*gawk*)	AWKS="${AWKS}gawk --posix
" ;;
	esac
fi
if [ -n "$awks_missing" ] && [ "${SWEEP:-0}" = 1 ]; then
	echo "${me:-run.sh}: missing:$awks_missing; the portability sweep needs all four" >&2
	exit 2
fi
if [ -z "$AWKS" ]; then
	echo "${me:-run.sh}: no awk found" >&2
	exit 2
fi
