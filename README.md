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
else, except `sort(1)` for `-s`.

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
usage: awklog [-cnsv] [-D mode] [-F format] [-q query] [file ...]

  -c          check the program only; do not evaluate or print results
  -D mode     evaluation engine: semi (default) or naive
  -F format   output format: text (default), csv or tsv
  -h          print this message and exit
  -n          suppress query output
  -q query    run a query after loading the program; repeatable
  -s          sort each query's rows
  -v          verbose diagnostics; repeatable

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
awklog: read 37 line(s) from 1 file(s)
awklog: 5 predicate(s), 5 input fact(s), 6 rule(s), 3 query(s), 2 stratum(s)
awklog: 42 derived fact(s) in 4 iteration(s), 10 rule run(s), 228 tuple scan(s)
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
`007` and `7` are one value.

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

**`-s`** sorts each query's rows through `sort(1)`, with `LC_ALL=C` unless
the environment sets `LC_ALL`, so the order is by bytes. Each query is sorted
on its own, so the blank-line-separated blocks stay intact. A csv field
containing a newline spans two lines, and `sort` sorts lines, so it would be
torn apart; awklog allows the combination but warns the first time it happens.
tsv has no such problem.

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

| status | meaning |
|---|---|
| 0 | success, including a run that printed warnings |
| 1 | an error in the program or a query: syntax, safety, stratification, or a run-time comparison error |
| 2 | a usage error: an unknown option, format or mode, a file operand that is missing, unreadable or a directory, or `awklog.awk` not found |

## Running awklog.awk directly

The wrapper is only a convenience. The engine runs on its own under any awk:

```sh
awk -f awklog.awk graph.dl
awk -v awklog_query='path(a, X)?' -v awklog_format=csv -f awklog.awk graph.dl
```

Every option has an `awklog_*` variable: `awklog_query` (several queries
separated by newlines), `awklog_format`, `awklog_mode`, `awklog_sort`,
`awklog_quiet`, `awklog_check` and `awklog_verbose`. Each can also be given as
an `AWKLOG_*` environment variable, which is how the wrapper passes them. The
environment is used because `awk -v` interprets backslash escapes in its value
and would corrupt a query holding a `\n` inside a string. When both are set,
`-v` wins, unless its value is empty: an empty `-v` assignment counts as not
given, so it cannot clear a setting the environment makes. Mind that same escape processing when passing a query with `-v`
yourself.

Two things the wrapper does are not done without it. `awklog_sort` runs a
plain `sort`, which orders rows by the current locale; set `LC_ALL=C` to get
the byte order `-s` gives. And a file operand awk cannot read is reported by
awk itself, in its own words.

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

## Not in this version

- An interactive mode. The spec describes one; it was written and then
  removed, and `-q`, `-v` and repeated runs cover the same ground (see
  `PLAN.md` §14.8).
- Arithmetic, aggregates (`count`, `min`, …), string ordering, floating point.
- Binding a variable with `=`: `=` only compares.
- JSON output.

## Development

```sh
make test     # every case under -D semi and -D naive, under every awk found
make sweep    # the same, but fail unless BWK awk, mawk and gawk are all installed
make lint     # sh -n, awk parse check, and a grep for non-POSIX constructs
```

Each case in `tests/cases/` is a program with its expected output. Every case
also runs through both evaluators with the whole model dumped, and the two
dumps must match. Some cases are symlinks into `examples/`, so that the
commands each example lists are tested too. `spec.md` is the design
specification and `PLAN.md` the implementation plan.

## License

2-clause BSD; see `LICENSE`.
