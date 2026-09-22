#!/bin/sh
#
# awklog test harness (PLAN.md section 12).
#
#	tests/run.sh [name ...]
#
# Each case in tests/cases is a set of files sharing one basename:
#
#	NAME.dl		the program (may contain embedded queries)
#	NAME.args	extra CLI arguments, one line	(default: none)
#	NAME.nodump	present when the case legitimately dumps no relations
#	NAME.out	expected stdout, byte-exact	(default: empty)
#	NAME.err	expected stderr, one pattern per line, each must match
#	NAME.status	expected exit status		(default: 0)
#
# Every case runs under -D semi and -D naive, under every awk found, and both
# engines must produce NAME.out.  Each case is then run a third time per awk
# with AWKLOG_DUMP=1, which prints every relation, and the two engines' dumps
# must be byte-identical: spec §76 compares the whole model, not only the
# rows the case's queries happen to ask for.
#
# Environment:
#	AWKS	newline-separated awk commands to test (default: those found)
#	AWKLOG	wrapper to test (default: the one beside this script)
#	VERBOSE	set to 1 to print every passing case

LC_ALL=C
export LC_ALL

here=${0%/*}
[ "$here" = "$0" ] && here=.
root=$(cd "$here/.." && pwd)
cases=$root/tests/cases

AWKLOG=${AWKLOG:-$root/awklog}
AWKLOG_AWK=${AWKLOG_AWK:-$root/awklog.awk}
export AWKLOG_AWK

if [ ! -x "$AWKLOG" ]; then
	echo "run.sh: $AWKLOG is not executable" >&2
	exit 2
fi

# Which awks to exercise.  gawk is run twice: once natively, once in POSIX mode.
if [ -z "${AWKS:-}" ]; then
	AWKS=$(
		for a in awk mawk gawk; do
			if command -v "$a" >/dev/null 2>&1; then
				echo "$a"
			fi
		done
		if command -v gawk >/dev/null 2>&1; then
			echo "gawk --posix"
		fi
	)
fi
if [ -z "$AWKS" ]; then
	echo "run.sh: no awk found" >&2
	exit 2
fi

tmp=${TMPDIR:-/tmp}/awklog-test.$$
mkdir -p "$tmp" || exit 2
trap 'rm -rf "$tmp"' 0
trap 'rm -rf "$tmp"; exit 1' 1 2 3 13 15

total=0
failed=0

# report_fail NAME AWKCMD MODE REASON
report_fail() {
	failed=$((failed + 1))
	echo "FAIL $1 [$2 -D $3]: $4"
}

# Compare actual stderr against NAME.err: every non-empty expected line must
# match somewhere in the output, so locations can be pinned without demanding
# byte-exact wording of everything else.
check_err() {
	expected=$1
	actual=$2
	missing=
	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		if ! grep -q "$pattern" "$actual"; then
			missing=$pattern
			break
		fi
	done < "$expected"
	if [ -n "$missing" ]; then
		echo "$missing"
		return 1
	fi
	return 0
}

run_case() {
	dl=$1
	awkcmd=$2
	mode=$3
	name=${dl%.dl}
	base=${name##*/}

	# No arguments by default: a case that prints rows pins the order the
	# evaluator produces them in.  Since M5 that order is per engine --
	# spec §63 leaves it unspecified and the two engines reach rows
	# differently -- so NAME.out has to be an order both agree on.  A case
	# that grows past the point where they do must either pin one engine
	# in NAME.args, the way eval-semi-scans and eval-naive-scans do, or
	# pass -s, which since M6 sorts each query's rows and leaves the two
	# engines nothing to disagree about.  What they must always agree on
	# is the model, and that is diff_case's job, not this one.
	args=
	[ -f "$name.args" ] && args=$(cat "$name.args")

	want_status=0
	[ -f "$name.status" ] && want_status=$(cat "$name.status")

	total=$((total + 1))
	AWK=$awkcmd; export AWK
	# stdin comes from /dev/null so that a case cannot reach the harness's
	# own, whatever the program under test decides to read.
	# shellcheck disable=SC2086
	"$AWKLOG" -D "$mode" $args "$dl" > "$tmp/out" 2> "$tmp/err" < /dev/null
	got_status=$?

	if [ "$got_status" -ne "$want_status" ]; then
		report_fail "$base" "$awkcmd" "$mode" \
			"exit status $got_status, expected $want_status"
		sed 's/^/    | /' "$tmp/err"
		return 1
	fi

	if [ -f "$name.out" ]; then
		want_out=$name.out
	else
		: > "$tmp/empty"
		want_out=$tmp/empty
	fi
	if ! diff -u "$want_out" "$tmp/out" > "$tmp/diff" 2>&1; then
		report_fail "$base" "$awkcmd" "$mode" "stdout differs"
		sed 's/^/    | /' "$tmp/diff"
		return 1
	fi

	if [ -f "$name.err" ]; then
		if ! missing=$(check_err "$name.err" "$tmp/err"); then
			report_fail "$base" "$awkcmd" "$mode" \
				"stderr does not match: $missing"
			sed 's/^/    | /' "$tmp/err"
			return 1
		fi
	fi

	[ "${VERBOSE:-0}" = 1 ] && echo "ok   $base [$awkcmd -D $mode]"
	return 0
}

# Differential check (spec §76): the same program through both engines must
# leave every relation identical.  AWKLOG_DUMP prints those relations, sorted,
# and suppresses the queries' own rows, whose order is an engine artefact and
# would otherwise make two agreeing engines look like they diverged.
#
# -D comes after the case's own arguments so that it wins over any -D they
# carry: eval-semi-scans and its naive twin pin one engine each, and comparing
# an engine with itself would prove nothing.
#
# The exit statuses must agree too, and a case that exits 0 must dump
# something.  A case that dies does so under both engines and leaves two empty
# dumps, which diff calls an agreement -- true, but it is an agreement about
# nothing, and without this guard a case that started failing for an unrelated
# reason would go on passing its differential check in silence.  The check-only
# cases have no model to compare and are skipped by name.
diff_case() {
	dl=$1
	awkcmd=$2
	name=${dl%.dl}
	base=${name##*/}

	args=
	[ -f "$name.args" ] && args=$(cat "$name.args")

	want_status=0
	[ -f "$name.status" ] && want_status=$(cat "$name.status")

	total=$((total + 1))
	AWK=$awkcmd; export AWK
	AWKLOG_DUMP=1; export AWKLOG_DUMP
	# shellcheck disable=SC2086
	"$AWKLOG" $args -D semi "$dl" > "$tmp/dump.semi" 2> /dev/null < /dev/null
	semi_status=$?
	# shellcheck disable=SC2086
	"$AWKLOG" $args -D naive "$dl" > "$tmp/dump.naive" 2> /dev/null < /dev/null
	naive_status=$?
	unset AWKLOG_DUMP

	if [ "$semi_status" -ne "$naive_status" ]; then
		report_fail "$base" "$awkcmd" "naive/semi" \
			"exit status $naive_status under naive, $semi_status under semi"
		return 1
	fi
	if [ "$semi_status" -ne "$want_status" ]; then
		report_fail "$base" "$awkcmd" "naive/semi" \
			"exit status $semi_status with AWKLOG_DUMP set, expected $want_status"
		return 1
	fi

	if ! diff -u "$tmp/dump.naive" "$tmp/dump.semi" > "$tmp/diff" 2>&1; then
		report_fail "$base" "$awkcmd" "naive/semi" \
			"the two engines disagree"
		sed 's/^/    | /' "$tmp/diff"
		return 1
	fi

	# A run that succeeded has a model; an empty dump means the hook, not
	# the engines, has stopped working.  -c never evaluates, so it has
	# nothing to dump and is not asked to, and a case that declares
	# NAME.nodump has no relations to begin with.
	if [ "$want_status" -eq 0 ] && [ ! -f "$name.nodump" ] &&
	   ! grep -q . "$tmp/dump.semi"; then
		case " $args " in
		*" -c "*)	;;
		*)	report_fail "$base" "$awkcmd" "naive/semi" \
				"exited 0 but dumped no relations"
			return 1 ;;
		esac
	fi

	[ "${VERBOSE:-0}" = 1 ] && echo "ok   $base [$awkcmd -D naive/semi]"
	return 0
}

# Selected names, or every case.
if [ "$#" -gt 0 ]; then
	list=
	for name in "$@"; do
		if [ -f "$cases/$name.dl" ]; then
			list="$list
$cases/$name.dl"
		else
			echo "run.sh: no such case: $name" >&2
			exit 2
		fi
	done
else
	list=$(ls "$cases"/*.dl 2>/dev/null)
fi

while IFS= read -r dl; do
	[ -z "$dl" ] && continue
	for mode in semi naive; do
		while IFS= read -r awkcmd; do
			[ -z "$awkcmd" ] && continue
			run_case "$dl" "$awkcmd" "$mode"
		done <<AWKS_EOF
$AWKS
AWKS_EOF
	done
	while IFS= read -r awkcmd; do
		[ -z "$awkcmd" ] && continue
		diff_case "$dl" "$awkcmd"
	done <<AWKS_EOF
$AWKS
AWKS_EOF
done <<LIST_EOF
$list
LIST_EOF

awk_list=$(echo "$AWKS" | tr '\n' ' ')
echo "ran $total check(s), $failed failure(s); awk: $awk_list"
[ "$failed" -eq 0 ] || exit 1
exit 0
