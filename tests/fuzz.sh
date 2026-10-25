#!/bin/sh
#
# awklog random differential test.
#
#	tests/fuzz.sh [count [first-seed]]	(default: 500 programs from seed 1)
#
# For each seed, tests/gen.awk writes a random safe, stratified program, and
# every awk found runs it under -D semi and -D naive twice: once with
# AWKLOG_DUMP set, which prints every relation, sorted, and once with -s,
# which prints the queries' own rows -- sorted, because their order is an
# engine artefact.  Checked for each program:
#
#	- both engines exit 0 and print nothing on stderr under every awk: the
#	  program is legal by construction, defines every predicate it
#	  reads and reads every predicate it derives, so any diagnostic, a
#	  warning included, is a bug;
#	- the two engines' output is byte-identical;
#	- every awk's output is byte-identical to the first awk's, which makes
#	  this a portability sweep over programs nobody wrote by hand;
#	- the dump is not empty, so that a broken hook cannot pass as agreement.
#
# A failure names its seed; awk -v seed=N -f tests/gen.awk reproduces the
# program under any awk, since the generator carries its own PRNG.
#
# Environment: AWKS, SWEEP, AWKLOG and AWKLOG_AWK as for tests/run.sh.

LC_ALL=C
export LC_ALL

here=${0%/*}
[ "$here" = "$0" ] && here=.
root=$(cd "$here/.." && pwd)

count=${1:-500}
first=${2:-1}

AWKLOG=${AWKLOG:-$root/awklog}
AWKLOG_AWK=${AWKLOG_AWK:-$root/awklog.awk}
export AWKLOG_AWK
unset AWKLOG_CHECK AWKLOG_FORMAT AWKLOG_MODE AWKLOG_QUERY AWKLOG_QUIET \
	AWKLOG_SORT AWKLOG_STDERR AWKLOG_VERBOSE AWKLOG_WERROR

me=fuzz.sh	# named in awks.sh's diagnostics
. "$here/awks.sh"

tmp=${TMPDIR:-/tmp}/awklog-fuzz.$$
mkdir -p "$tmp" || exit 2
trap 'rm -rf "$tmp"' 0
trap 'rm -rf "$tmp"; exit 1' 1 2 3 13 15

failed=0
rows=0
empty=0
nawks=0
# Totals of the generator's own summary line, to show what the run covered.
tally="facts=0 rules=0 recursive=0 negations=0 comparisons=0 numeric=0"

fail() {
	failed=$((failed + 1))
	echo "FAIL seed $seed [$1]: $2 (awk -v seed=$seed -f tests/gen.awk)"
	[ -n "$3" ] && sed 's/^/    | /' "$3"
}

seed=$first
last=$((first + count - 1))
while [ "$seed" -le "$last" ]; do
	awk -v seed="$seed" -f "$here/gen.awk" > "$tmp/prog.dl" || exit 2
	tally=$(sed -n 1p "$tmp/prog.dl" | awk -v tally="$tally" '{
		n = split(tally, t, " ")
		for (i = 1; i <= n; i++) {
			split(t[i], kv, "=")
			for (j = 2; j <= NF; j++)
				if (index($j, kv[1] "=") == 1)
					kv[2] += substr($j, length(kv[1]) + 2)
			printf "%s%s=%d", (i > 1 ? " " : ""), kv[1], kv[2]
		}
	}')
	ref=
	while IFS= read -r awkcmd; do
		[ -z "$awkcmd" ] && continue
		AWK=$awkcmd; export AWK
		for mode in semi naive; do
			AWKLOG_DUMP=1 "$AWKLOG" -D "$mode" "$tmp/prog.dl" \
				< /dev/null > "$tmp/dump.$mode" 2> "$tmp/err.$mode"
			status=$?
			if [ "$status" -eq 0 ]; then
				echo "--- query rows" >> "$tmp/dump.$mode"
				"$AWKLOG" -s -D "$mode" "$tmp/prog.dl" < /dev/null \
					>> "$tmp/dump.$mode" 2>> "$tmp/err.$mode"
				status=$?
			fi
			if [ "$status" -ne 0 ]; then
				fail "$awkcmd -D $mode" "exit status $status" \
					"$tmp/err.$mode"
				continue 2
			fi
			if [ -s "$tmp/err.$mode" ]; then
				fail "$awkcmd -D $mode" "wrote to stderr" \
					"$tmp/err.$mode"
				continue 2
			fi
		done
		if ! diff -u "$tmp/dump.naive" "$tmp/dump.semi" > "$tmp/diff"; then
			fail "$awkcmd" "naive and semi disagree" "$tmp/diff"
			continue
		fi
		if ! grep -q '	#	' "$tmp/dump.semi"; then
			fail "$awkcmd" "exited 0 but dumped no relations"
			continue
		fi
		if [ -z "$ref" ]; then
			ref=$awkcmd
			cp "$tmp/dump.semi" "$tmp/dump.ref"
			# Derived rows: those of the p* predicates, less the
			# per-predicate size lines.  A few programs derive
			# nothing, and a run where most did would be no test.
			n=$(grep '^p' "$tmp/dump.ref" | grep -c -v '	#	')
			rows=$((rows + n))
			[ "$n" -eq 0 ] && empty=$((empty + 1))
		elif ! diff -u "$tmp/dump.ref" "$tmp/dump.semi" > "$tmp/diff"; then
			fail "$awkcmd" "dump differs from $ref's" "$tmp/diff"
		fi
	done <<AWKS_EOF
$AWKS
AWKS_EOF
	seed=$((seed + 1))
done

awk_list=$(echo "$AWKS" | tr '\n' ' ')
echo "fuzz: $count program(s) from seed $first, $failed failure(s); awk: $awk_list"
echo "fuzz: $rows derived row(s), $empty program(s) deriving none; generated $tally"
if [ -n "$awks_missing" ]; then
	echo "fuzz.sh: warning: missing:$awks_missing; the portability sweep" \
		"is incomplete" >&2
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
