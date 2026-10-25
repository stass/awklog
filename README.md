# awklog

awklog is Datalog in AWK: facts, rules, recursion, queries and stratified
negation in a single portable AWK program with no dependencies.

```prolog
% path.dl
edge(a, b).
edge(b, c).
edge(c, d).

path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).

path(a, X)?
```

```text
$ awklog path.dl
b
c
d
```

It is two files: `awklog`, a POSIX `sh` wrapper that parses the command line,
and `awklog.awk`, the whole engine. It runs under any POSIX awk — BWK awk (the
one on macOS and the BSDs), mawk and gawk are all tested — and needs nothing
else.

## Contents

- [Install](#install)
- [Usage](#usage)
- [The language](#the-language)
- [Semantics](#semantics)
- [Numbers](#numbers)
- [Output formats](#output-formats)
- [Diagnostics and exit status](#diagnostics-and-exit-status)
- [Running awklog.awk directly](#running-awklogawk-directly)
- [Limits](#limits)
- [Portability](#portability)
- [Design](#design)
- [Not in this version](#not-in-this-version)
- [Development](#development)

## Install

Nothing needs building. From a checkout, `./awklog` runs as is: it uses the
`awklog.awk` sitting beside it.

```sh
make install                      # /usr/local/bin/awklog, /usr/local/libexec/awklog.awk
make install PREFIX=$HOME/.local  # anywhere else
make uninstall
```

`make install` records its `LIBEXECDIR` in the installed wrapper, so an
install under any prefix finds its own interpreter.

## Usage

```text
usage: awklog [-Wcnsv] [-D mode] [-F format] [-q query] [file ...]

  -c          check the program only; do not evaluate or print results
  -D mode     evaluation engine: semi (default) or naive
  -F format   output format: text (default), csv or tsv
  -h          print this message and exit
  -n          suppress query output
  -q query    run a query after loading the program; repeatable
  -s          sort each query's rows by value
  -v          verbose diagnostics; repeatable
  -W          treat warnings as errors

With no file operands the program is read from standard input.

Environment:
  AWK               awk to run (default: awk)
  AWKLOG_AWK        path to awklog.awk
  AWKLOG_LIBEXEC    installed awklog.awk, used when no sibling copy exists
```

Every file named on the command line is part of one program, as if they were
concatenated; with no files, or where a file is named `-`, the program is read
from standard input.
Queries written in the program run first, in source order, then each `-q` in
the order given. When more than one query runs, a blank line separates their
results.

```sh
awklog examples/graph.dl
awklog -s -q 'path(X, Y)?' examples/graph.dl
awklog -s -F csv -q 'unreachable(X, Y)?' examples/graph.dl
awklog -c examples/policy.dl          # check only: silent and exit 0 if the program is sound
awklog facts.dl rules.dl              # one program from several files
```

`-v` reports what was read and what evaluation cost, on standard error; a
second `-v` adds one line per predicate:

```text
$ awklog -v -v -n examples/graph.dl
awklog: read 40 line(s) from 1 file(s)
awklog: 5 predicate(s), 5 input fact(s), 6 rule(s), 4 query(s), 2 stratum(s)
awklog: 42 derived fact(s) in 4 iteration(s), 10 rule run(s), 248 tuple scan(s)
awklog: edge/2: 5 tuple(s), stratum 0
awklog: node/1: 6 tuple(s), stratum 0
awklog: path/2: 13 tuple(s), stratum 0, recursive
awklog: cyclic/1: 3 tuple(s), stratum 0
awklog: unreachable/2: 20 tuple(s), stratum 1
```

`-D naive` selects the naive evaluator, which re-runs every rule until nothing
changes. It computes exactly what the default semi-naive evaluator does, only
more slowly; it exists as the reference the test suite checks the fast engine
against.

The `examples/` directory has three complete programs: `graph.dl`
(reachability over a graph with a cycle), `project.dl` (a task tracker) and
`policy.dl` (access control with a policy check). Each one lists, at the top,
the commands worth running on it.

## The language

A program is a sequence of facts, rules and queries, each ended by a `.` or,
for a query, a `?`. Whitespace and line breaks between tokens do not matter;
`%` starts a comment that runs to the end of the line.

```prolog
% Facts: ground rows of a relation.
status(parser, todo).
status(planner, todo).
depends(planner, parser).
priority(parser, 10).
title(parser, "Rewrite parser").
initialized.                        % a zero-arity predicate: simply true

% Rules: the head holds wherever the body does.
unfinished(X) :- status(X, todo).
blocked(X) :- depends(X, Y), unfinished(Y).
ready(X) :- unfinished(X), not blocked(X).
urgent(X) :- unfinished(X), priority(X, P), P >= 10.

% Queries.
ready(X)?                           % one column per named variable
depends(X, Y), unfinished(Y)?       % a query may be a whole body
blocked(parser)?                    % no variables: prints true or false
```

**Names.** A predicate is identified by its name *and* its arity, so `foo/1`
and `foo/2` are unrelated predicates. Predicate names and symbols begin with a
lowercase ASCII letter, variables with an uppercase one; after the first
letter, both may use `A-Z a-z 0-9 _`.

**`not` is a reserved word.** It introduces a negated literal, so there can be
no predicate or symbol called `not`.

**Values** come in three types:

| type | written as | notes |
|---|---|---|
| symbol | `parser`, `todo`, `foo_bar` | an identifier starting with a lowercase letter |
| string | `"Rewrite parser"` | escapes `\\` `\"` `\n` `\t` `\r` and no others; a string may not span lines |
| integer | `0`, `10`, `-42` | optional `-`, then digits; see [Numbers](#numbers) |

**Variables** are local to the rule or query they appear in. `_` is the
anonymous variable, and every `_` is a different one: `pair(_, _)` matches
any pair, not only pairs of equal values.

**Comparisons** are `=`, `!=`, `<`, `<=`, `>` and `>=`. There is no
arithmetic: `-` is only ever the sign of an integer literal.

## Semantics

Evaluation is bottom-up. Every rule is applied until no new row can be
derived, and then the queries read the finished relations. The order of
rules in a file, and of literals in a body, does not change the result.

- **Relations are sets.** A fact stated twice, or a row derived twice, is one
  row. A query prints each distinct row once.
- **Recursion** may be direct or mutual, and cyclic data is fine: evaluation
  stops when a round derives nothing new.
- **Safety.** Every variable in a rule's head, in a negated literal, or in a
  comparison must also appear in a positive literal of the same body. The
  same holds for a query's variables. `=` does not bind a variable in this
  version; it only compares two values that are already known. Anything else
  is rejected before evaluation, with the location of the offending literal.
- **Stratified negation.** `not p(X)` is true when that row is absent from
  `p`, and awklog arranges for `p` to be complete before any rule that negates
  it runs. A program in which a predicate depends on itself through a
  negation (`a(X) :- b(X), not c(X).  c(X) :- b(X), not a(X).`) has no such
  arrangement and is rejected.
- **Values are typed.** `=` and `!=` compare type and value together, so the
  symbol `foo`, the string `"foo"` and the integer `42` are all different
  from each other and from the string `"42"`. `<`, `<=`, `>` and `>=` compare
  integers only. A symbol or string constant written in an ordering
  comparison is rejected when the program is checked. A non-integer value
  that reaches one through a variable is a run-time error at that
  comparison's location, not a silent "no match".
- **An undefined predicate is empty.** A predicate used in a body or query but
  given no facts and no rules is treated as an empty relation, with a warning
  on standard error. This lets a program run when the file holding some of its
  facts is left out; it also means a misspelt predicate shows up as a warning
  and not as an error.
- **A derived predicate nothing reads draws a warning.** A predicate defined
  by at least one rule, but named in no rule body (negated or not) and in no
  query (in the program or given with `-q`), is reported at the head of its
  first rule: `rules.dl:4:1: warning: predicate eror/1 is derived but never
  used`. Such a rule computes nothing anyone sees, and the usual cause is a
  misspelt head, which would otherwise quietly drop the check the rule was
  written to be. The warning applies even when the run has no queries at
  all, as in `awklog -c rules.dl`: a predicate no rule reads computes
  nothing observable there either. A predicate defined only by facts never
  draws it, because a fact file commonly carries relations a given program
  does not use. "Read" means named in some body or query, so predicates
  that read only each other count as used: a recursive predicate whose own
  rule is its only reader, or two mutually recursive ones that no query
  reads, draw no warning.

## Numbers

awklog stores integers as the host awk stores numbers: IEEE-754 doubles on
every awk it is tested with. That makes integers exact from
−9,007,199,254,740,992 to 9,007,199,254,740,992 (±2⁵³) and **not exact
beyond**. Outside that range, two literals that round to the same double
become the same value:

```text
$ printf 'n(9007199254740992).\nn(9007199254740993).\nn(X)?\n' | awklog
9007199254740992
```

Very large values also print in exponent form: `12345678901234567890` comes
out as `1.2345678901234567e+19`. A leading zero is not significant, so
`007` and `7` are one value. A literal beyond the largest double, about
1.8 × 10³⁰⁸, is an error where it is written.

If exact large numbers matter, as they do for 64-bit identifiers, hashes and
timestamps in nanoseconds, write them as strings or symbols. Equality on
those is exact, and ordering comparisons are not defined on them anyway.

## Output formats

A row is one line: its columns are the query's named variables, in the order
they first appear in the query. A query with no named variables prints `true`
or `false`. Rows come out in whatever order evaluation reaches them. That
order is not specified, and it differs between `-D naive` and `-D semi`, so
use `-s` wherever it matters.

These formats are stable, and the rules below are their specification:

- **text** (default). Columns are separated by one space. Symbols and integers
  are printed as they are. A string is printed bare unless it is empty or
  contains a space, tab, newline, carriage return or double quote. In that
  case it is printed in double quotes, with the same escapes as the source
  language, so it can be read back.
- **csv** (RFC 4180). Columns are separated by commas. A field is quoted when
  it contains a comma, double quote, CR or LF, or begins or ends with a space.
  Inside quotes, a double quote is doubled. Nothing else is escaped.
- **tsv**. Columns are separated by one tab. Fields are never quoted. A
  backslash, tab, newline and carriage return are written as `\\`, `\t`, `\n`
  and `\r`, so every row is exactly one line and every column exactly one
  field.

In all three, a value is printed without its type, so the symbol `foo` and
the string `"foo"` look alike, and a query can print two rows that look
identical but are distinct. (text still tells them apart when a string needs
quoting.)

**`-s`** sorts each query's rows by their values, not by their printed text.
Rows compare column by column, from the first, and values compare in this
order:

- integers first, then symbols, then strings;
- integers numerically, so `9` comes before `10` and `-20` before `-3`;
  beyond 2⁵³ they compare as the doubles they are stored as
  (see [Numbers](#numbers));
- symbols by spelling and strings by contents, byte by byte as unsigned
  bytes, a prefix before any longer value: `""` before `"a"` before `"ab"`,
  and `"Z"` before `"a"` before any byte above 0x7f.

This is the order relic's `-s` sorts by. It is total, since no two rows of a
result are equal, so a sorted result is the same under both engines and
every awk. Each query is sorted on its own, so the blank-line-separated
blocks stay intact, and the output format does not affect the order: a csv
value holding a newline sorts with its row. Byte order needs the C locale,
since BWK awk and gawk `--posix` otherwise compare strings by the locale's
collation; the wrapper always runs awk with `LC_ALL=C`.

## Diagnostics and exit status

Errors and warnings go to standard error as `file:line:column: message`. A
program read from standard input is called `<stdin>`, and a query given with
`-q` is called `<query>`:

```text
bad.dl:2:8: syntax error: expected ')', found 'c'
rules.dl:1:1: error: unsafe rule: variable 'X' in the head of p/1 is not bound by a positive body literal
<stdin>:1:1: error: program contains recursion through negation: a/1
<query>:1:8: syntax error: expected a term, found end of input
```

The first error stops the run; there is no error recovery. Usage errors carry
no location: `awklog: unknown output format: json`, `awklog: notes.dl: cannot
open`.

Warnings say `warning:` where errors say `error:`. They do not stop the run
or change the exit status. The warnings are:

- an undefined predicate ([Semantics](#semantics));
- a derived predicate nothing reads ([Semantics](#semantics)).

**`-W`** treats warnings as errors. Each is reported with `error:` in place
of `warning:` and the same text, and, like any error, the first one stops the
run with status 1, before anything is evaluated or printed. Stopping at the
first matches the rest of awklog: fix it and run again. A program that
draws no warning runs under `-W` exactly as without it, so
`awklog -c -W rules.dl` is a check that fails on anything doubtful:

```text
$ awklog -c -W rules.dl
rules.dl:4:1: error: predicate eror/1 is derived but never used
```

| status | meaning |
|---|---|
| 0 | success, including a run that printed warnings without `-W` |
| 1 | an error in the program or a query: syntax, safety, stratification, or a run-time comparison error; with `-W`, also any warning |
| 2 | a usage error: an unknown option, format or mode, an on/off switch other than 0 or 1 when `awklog.awk` runs directly, a file operand that is missing, unreadable or a directory, or `awklog.awk` not found |

## Running awklog.awk directly

The wrapper is only a convenience. The engine runs on its own under any awk:

```sh
awk -f awklog.awk graph.dl
awk -v awklog_query='path(a, X)?' -v awklog_format=csv -f awklog.awk graph.dl
```

Every option has an `awklog_*` variable: `awklog_query` (several queries
separated by newlines), `awklog_format`, `awklog_mode`, `awklog_sort`,
`awklog_quiet`, `awklog_check`, `awklog_verbose` and `awklog_werror`. Each
can also be given as an `AWKLOG_*` environment variable, which is how the
wrapper passes them. The environment is used because `awk -v` interprets
backslash escapes in its value and would corrupt a query holding a `\n`
inside a string. When both are set, `-v` wins, unless its value is empty: an
empty `-v` assignment counts as not given, so it cannot clear a setting the
environment makes. Mind that same escape processing when passing a query
with `-v` yourself. The on/off switches (`awklog_check`, `awklog_quiet`,
`awklog_sort` and `awklog_werror`) take `0` or `1`; any other value is a
usage error rather than a quiet "off".

Two things the wrapper does are not done without it. It runs awk with
`LC_ALL=C`, because BWK awk and gawk `--posix` compare strings by the
locale's collation; set `LC_ALL=C` yourself to get the byte order `-s`
promises. And a file operand awk cannot read is reported by awk itself, in
its own words.

Diagnostics go to `/dev/stderr`. On a system without it, set `AWKLOG_STDERR`
(or `-v awklog_stderr=`) to another file.

## Limits

awklog is meant for small-to-medium programs: hundreds of rules and tens of
thousands of facts. There are no indexes, so a join scans whole relations,
and a rule like `p(X, Z) :- a(X, Y), b(Y, Z).` can cost |a| × |b| row
comparisons. awklog reduces this by reordering each body so that
already-bound variables and small relations are used first, and recursion
only revisits rows that are new.

The join recurses once per body literal. Bodies of a dozen literals are tested
and fine under every awk here.

Under BWK awk, string operations cost time proportional to the length of the
line being scanned, so one very long line is slow to read in: 20,000 facts
take about 0.5 s written one per line, but about 8 s written on a single line.
Keep to roughly one statement per line and this does not come up.

## Portability

`awklog.awk` uses POSIX awk only: no gawk extensions, no arrays of arrays, no
`asort`, no `length()` of an array, no whole-array `delete`. The one exception
is `fflush()`, which POSIX added in its 2024 edition and every awk in
practical use has long had. The wrapper is POSIX `sh`. The test suite runs
every case under each of these, and all pass:

- BWK awk 20200816 (macOS `/usr/bin/awk`)
- mawk 1.3.4
- gawk 5.4.1
- gawk 5.4.1 `--posix`

## Design

awklog aims to be small enough to read in one sitting, so it favours plain
code over clever code and gives up speed where speed would cost clarity.

**Two files.** The `awklog` wrapper parses the command line with `getopts`,
checks the options and file operands, and runs awk on `awklog.awk`. It passes
settings in the environment (`AWKLOG_*`) rather than with `awk -v`, because
`-v` would process backslash escapes in a query. `awklog.awk` does everything
else.

**One pass, then a pipeline.** awk's main loop only collects source lines,
with the file and line number each came from. All the real work happens in
`END`, in order:

1. **Lex and parse.** A hand-written lexer walks a (line, column) cursor over
   the saved lines, so every token knows its `file:line:column` for free. The
   parser is recursive descent with one token of lookahead. Facts, rules and
   queries all become *rules*: a fact is a rule with an empty body, and a query
   is a rule whose head is its list of named variables. Everything gets an
   integer id and lives in flat arrays (`rule_lit_pred[r, i]`,
   `term_val[r, i, k]`, …), since POSIX awk has no nested arrays. Each variable
   becomes a small numbered slot, so evaluation never looks up a name.
2. **Load facts** into the tuple store (below).
3. **Check safety.** For each rule, collect every variable that some positive
   literal binds, then insist that every variable in the head, in a negation
   and in a comparison is among them. This ignores the order the body is
   written in, because evaluation reorders it anyway. The same stage warns
   about a predicate that is read but never defined, and one that is derived
   but never read.
4. **Stratify.** Build the predicate dependency graph (an edge from each rule
   head to each body predicate, marked positive or negative) and take its
   transitive closure. A negative edge whose target leads back to its source
   is recursion through negation, and the program is rejected. Otherwise a
   simple relaxation gives each predicate the lowest stratum such that it sits
   at or above what it uses and strictly above what it negates. The graph is
   small, so plain O(P³) loops do this without any SCC algorithm.
5. **Evaluate** one stratum at a time, lowest first. Lower strata are
   complete and never change while a higher one runs, which is what makes
   `not` well defined.
6. **Run queries** against the finished relations, in source order and then
   `-q` order. A query joins exactly like a rule, but the last step prints a
   row instead of storing a tuple. Under `-s` a query keeps its rows and
   sorts them before printing, with a merge sort over a typed comparison,
   since POSIX awk has no sort function.

**Values and tuples.** Every constant is stored with a type tag: `s:foo` for
a symbol, `q:foo` for a string, `n:42` for a number. That's why `foo`,
`"foo"` and `42` never compare equal. A row of a relation (a tuple) is stored
once, under a key made of the predicate id and its encoded arguments joined
with awk's `SUBSEP` byte. A repeated fact or re-derived row is therefore one
hash lookup, and relations are sets for free. Two details keep that key
honest. A backslash or `SUBSEP` byte inside a string is escaped, so no string
can forge another row's key. And numbers are written with `%d`, or with
`%.17g` beyond 2⁵³, rather than leaving the spelling to the host awk.

**Joins.** A rule body is evaluated by a recursive nested loop over one
shared set of variable bindings. Each level scans the relation for its
literal, binds what it can, recurses into the next literal, then undoes its
own bindings. Nothing is materialised between literals, and the recursion is
only as deep as the body is long. A negation is a single key lookup, because
safety guarantees all its arguments are bound. A comparison is a test on the
current bindings. There are no indexes. Instead, before each run of a rule,
the body is reordered: filters go first as soon as their variables are bound,
then the positive literal with the most bound arguments, then the smallest
relation, then the earliest in the source. The tie-breaks make the order
deterministic.

**Semi-naive evaluation.** Within a stratum, every rule first runs once over
the full relations. After that, any missing derivation must use a row that
is new since then. So the loop keeps a *delta* (the rows the last round
added) and re-runs only the rules that read a predicate this stratum
derives. Each such rule runs once per such body position, with that position
reading the delta and the rest reading full relations. The first delta is
the whole relation rather than just the new rows. That costs a little
repeated work, but it can't miss derivations from a predicate that has both
facts and rules. A stratum that reads nothing it derives never enters the
loop.

**The naive engine as a reference.** `-D naive` re-runs every rule in the
stratum until a whole pass adds nothing. It shares the join, the planner and
the tuple store with the semi-naive engine, which differs only in which rules
it re-runs and what one literal scans. The test suite runs everything
through both engines and requires identical results. The comparison uses an
undocumented `AWKLOG_DUMP=1` hook that prints every relation, sorted and typed.

**Portability habits.** Membership is always tested with `(k in a)`, since
`if (a[k])` silently creates the element. Arrays are emptied with a loop,
since `delete a` is not POSIX. `CONVFMT`, `OFMT` and `SUBSEP` are pinned in
`BEGIN`, because changing them would quietly change which values count as
the same.

## Not in this version

- An interactive mode. `-q`, `-v` and repeated runs cover the same ground,
  and keeping the engine batch-only means an error always ends the run.
- Arithmetic, aggregates (`count`, `min`, …), string ordering, floating point.
- Binding a variable with `=`: `=` only compares.
- JSON output.

## Development

```sh
make test     # every case under -D semi and -D naive, under every awk found,
              # then 25 random programs through both engines
make sweep    # the same, but fail unless BWK awk, mawk and gawk are all installed
make fuzz     # 500 random programs through both engines (FUZZ="count seed")
make lint     # sh -n, awk parse check, and a grep for non-POSIX constructs
```

Each case in `tests/cases/` is a program with its expected output. Every case
also runs through both evaluators with the whole model dumped, and the two
dumps must match. Some cases are symlinks into `examples/`, so that the
commands each example lists are tested too. `tests/gen.awk` writes random
safe, stratified programs — recursion, mutual recursion, negation,
comparisons, all three value types — and `tests/fuzz.sh` runs each through
both evaluators under every awk: the dumps must match between the engines and
between the awks. A failure names its seed, and the generator carries its own
random number generator, so `awk -v seed=N -f tests/gen.awk` rebuilds the same
program under any awk.

## License

2-clause BSD; see `LICENSE`.
