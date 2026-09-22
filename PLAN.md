# awklog — Implementation Plan

Implementation plan for `awklog`, a tiny stratified Datalog interpreter in portable
AWK, per `spec.md`.

**Naming.** The spec text uses `Dawk`/`dawk`. Everywhere it does, read:

| spec | this project |
|---|---|
| `Dawk` (prose) | `awklog` |
| `dawk` (wrapper) | `awklog` |
| `dawk.awk` | `awklog.awk` |
| `DAWK_*` env | `AWKLOG_*` |
| `dawk_query`, `dawk_format` | `awklog_query`, `awklog_format` |
| `dawk>` prompt | `awklog>` |
| `.dl` file suffix | `.dl` (unchanged) |
| `Rivet` (future C engine) | unchanged, out of scope |

Source language, semantics, CLI shape, and the 700–1,200-line budget are taken from
the spec unchanged except where §14 (*Deliberate deviations*) says otherwise.

---

## 1. Deliverables

```text
awklog/
    awklog              # POSIX sh wrapper (getopts)
    awklog.awk          # the interpreter — the whole engine
    Makefile            # optional: test, install, lint targets
    README.md
    LICENSE             # 2-clause BSD
    spec.md             # existing design spec
    PLAN.md             # this file
    examples/
        graph.dl
        project.dl
        policy.dl
    tests/
        run.sh          # POSIX sh harness, runs under every awk found
        gen.awk         # random program generator (differential testing)
        cases/          # NAME.dl + NAME.out / NAME.err / NAME.status
```

No build system is required to *run* awklog; the Makefile is convenience only
(`make test`, `make install`).

---

## 2. Architecture

Single AWK program, one pass over input to collect source, all work in `END`:

```awk
BEGIN { init() }
      { source_add_line(FILENAME, FNR, $0) }
END   { parse_all(); check_program(); stratify(); evaluate(); run_queries(); repl() }
```

Pipeline stages, each a function group with its own globals:

```text
source lines  →  lexer  →  parser  →  predicate/rule/term tables
                                          ↓
                                   semantic checks (safety)
                                          ↓
                             dependency graph → stratification
                                          ↓
                      per-stratum evaluation (seed pass + semi-naive deltas)
                                          ↓
                                   queries → formatted rows
```

`init()` must run in `BEGIN` (not `END`) only for things needed while reading —
in practice just option decoding and `STDERR`/`SUBSEP` setup.

---

## 3. Module map and line budget

Target ≈1,050 lines of readable AWK (spec §88.11: 700–1,200). Budget per group,
used as a review gate — a group going 50% over its budget is a design smell:

| Group | Functions | Lines |
|---|---|---|
| Preamble, options, `init`, `die`, `array_clear` | | 70 |
| Source collection | `source_add_line` | 20 |
| Lexer | `lex_start`, `lex_next`, `lex_peek`, `lex_string`, `lex_error` | 130 |
| Parser | `parse_program`, `parse_statement`, `parse_rule`, `parse_query`, `parse_body`, `parse_atom`, `parse_term`, `parse_comparison` | 180 |
| Symbols/values | `predicate_get`, `predicate_label`, `value_encode`, `value_decode` | 80 |
| Tuple store | `tuple_key`, `tuple_add`, `tuple_exists_p` | 60 |
| Checks | `check_program`, `check_rule_safety`, `check_comparisons` | 100 |
| Graph + strata | `build_deps`, `stratify`, `stratum_members`, `recursive_p` | 90 |
| Evaluation | `evaluate`, `eval_stratum`, `eval_rule`, `join`, `match_tuple`, `eval_compare`, `eval_negation`, `emit_head` | 170 |
| Semi-naive | `delta_seed`, `delta_round`, `delta_rotate` | 70 |
| Query | `query_run`, `query_emit` | 80 |
| Output | `print_row`, `format_value`, `csv_quote`, `tsv_escape`, `text_quote` | 90 |
| REPL + stats | `repl`, `repl_command`, `print_stats`, `dump_relations` | 110 |

---

## 4. Data representation

Flat 1-D and 2-D associative arrays only; `a[x, y]`, never `a[x][y]` (spec §69).

```awk
# source
src_n; src_text[i]; src_file[i]; src_fnr[i]

# lexer state (globals, not return values)
lex_i; lex_col                 # cursor: source line index, 1-based column
tok_kind; tok_text; tok_ln; tok_col
tok_peeked                     # one-token pushback for lex_peek()

# predicates
pred_n; pred_name[p]; pred_arity[p]; pred_id[name, arity]
pred_has_rule[p]; pred_has_fact[p]

# tuples
tuple_n; tuple_pred[t]; tuple_arg[t, k]
tuple_exists[key] = t          # key = p SUBSEP enc1 SUBSEP enc2 ...
pred_tuple[p, n] = t; pred_tuple_count[p]

# rules  (queries are rules with a synthetic head)
rule_n; rule_head_pred[r]; rule_head_arity[r]; rule_line[r]; rule_col[r]
rule_head_kind[r, k]; rule_head_val[r, k]
rule_body_n[r]
rule_lit_kind[r, i]            # 1 positive, 2 negative, 3 comparison
rule_lit_pred[r, i]            # positive/negative
rule_lit_op[r, i]              # comparison: = != < <= > >=
rule_lit_arity[r, i]
term_kind[r, i, k]             # 1 var(slot), 2 symbol, 3 string, 4 number
term_val[r, i, k]              # slot id, or encoded constant
rule_var_n[r]; rule_var_name[r, slot]   # "" for anonymous
rule_var_slot[r, name]

# bindings (single environment, undone on backtrack — see §6)
bind_has[slot]; bind_val[slot]

# deltas
delta_t[p, n]; delta_n[p]; next_t[p, n]; next_n[p]
```

### Value encoding (spec §26)

`s:` symbol, `q:` string, `n:` number — the *encoded* form is what the engine
compares, hashes, and stores; decoding happens only in output.

Two hazards the spec does not name, both must be handled in `value_encode`:

1. **Numeric stringification.** `"" x` uses `CONVFMT` and turns `1000000` into
   `1e+06` on some awks. Always build numbers with `sprintf("%d", v)` when
   `v == int(v) && abs(v) < 2^53`, else `sprintf("%.17g", v)`. Set
   `CONVFMT = OFMT = "%.17g"` in `init()` as a belt-and-braces measure.
2. **`SUBSEP` collisions.** Tuple keys join encoded values with `SUBSEP` (`\034`).
   A string literal containing `\034` could forge another tuple's key. In
   `value_encode`, escape `\` as `\\` and `SUBSEP` as `\S`, making key
   construction injective. Cost: two `gsub`s per string constant, once at parse.

### Deduplication (spec §25)

`tuple_add(p, n, argv_prefix)` builds the key, returns the tuple id and sets a
global `tuple_added` to 1/0 (AWK has no multiple return values). Membership tests
always use `(key in tuple_exists)` — never `tuple_exists[key]`, which would
autovivify and silently grow the array.

---

## 5. Lexer and parser

- **Cursor over the line array, not a concatenated buffer.** The spec (§19)
  suggests concatenating all input into one string and lexing from an offset;
  a `(line, column)` cursor over `src_text[]` gives §20 diagnostics
  (`file:line:col: message`) for free with no offset→line mapping table, and
  costs nothing extra. Statements still span lines because the lexer advances
  through line boundaries transparently.
- Token kinds exactly as spec §18. `not` is a **reserved word**, not an
  identifier — documented in the README, since it forbids a `not/N` predicate.
- Whitespace and `%`-to-end-of-line comments are skipped between tokens, so `%`
  inside a string literal is safe by construction (spec §16).
- String literals do not span lines; escapes `\\ \" \n \t \r` (spec §7.2). Any
  other escape is a lex error naming the offending character.
- One-token lookahead (`lex_peek`) is enough for the whole grammar (spec §17):
  after an `atom`, peek decides fact vs. rule; at a term, peek decides whether an
  `IDENT` starts an atom or is a bare symbol; after a term, peek decides
  comparison vs. next literal.
- Integers: optional `-`, then digits. `-` is *only* a sign on a numeric literal;
  there is no arithmetic in v1.
- Zero-arity atoms (`initialized.`) parse as arity 0 with no parens (spec §17).

**Variable slots** are assigned per rule/query at parse time (spec §22):
`rule_var_slot[r, "X"]` → small int; `_` gets a fresh slot with empty name every
occurrence (spec §9). Named-variable slot order = order of first appearance,
which is also the query output column order (spec §14).

**Diagnostics** go to `STDERR` (default `/dev/stderr`, overridable with
`-v awklog_stderr=`) as `file:line:col: message`, then `exit 1`. Because `exit`
inside a function called from the main rule would jump to `END`, every stage runs
inside `END`, so `die()` terminates immediately with the right status (spec §65:
0 ok, 1 program error, 2 usage — 2 is the wrapper's, for bad options).

Parse errors are fatal on the first error; no error recovery in v1 (a
resynchronise-on-`.` recovery loop is a plausible later addition, but doubles the
parser's state space for little gain in a tool whose files are small).

---

## 6. Safety checking (spec §32–34, 50, 51)

Computed per rule, **order-independent** (spec §33), before any reordering:

```text
posbound(r) = { every variable slot appearing in a positive body literal }

error unless  vars(head)           ⊆ posbound(r)     # range restriction
error unless  vars(negative lit)   ⊆ posbound(r)     # negation safety
error unless  vars(comparison)     ⊆ posbound(r)     # comparison safety
```

`=` is a filter only in v1 (spec §51): both sides must be bound or constant, so it
falls under the comparison rule with no special case. Comparisons whose operands
are both constants are folded and checked at parse time; an ordering comparison
between two non-numeric constants is a compile-time error.

Queries are checked identically — a query is a rule with a synthetic head
carrying its named variables (spec §14).

**Undefined predicates** (appearing in a body or query but in no fact and no rule
head): treated as an empty relation, with a warning on `STDERR` naming
`name/arity` and the location. stdout stays clean so pipelines are unaffected,
and `-c` lists them. *(Alternative considered: hard error, which catches typos but
makes "this fact file may be absent" programs unusable. Flip this in one line if
strictness turns out to be preferable.)*

---

## 7. Stratification (spec §36–38)

`dep_pos[p, q]`, `dep_neg[p, q]` from every rule head→body-literal pair. Then the
spec's iterative relaxation: repeat over all pairs, raising `stratum[p]` to
`stratum[q]` for positive edges and to `stratum[q] + 1` for negative edges, until
a pass makes no change. If any `stratum[p] >= pred_n`, the program has recursion
through negation → error `file: error: program contains recursion through
negation` (spec §38), naming one predicate on the cycle (cheap: the predicate that
tripped the bound).

Convergence is O(P³) worst case with P predicates — fine at the intended scale
(spec §36), and it avoids an SCC implementation entirely.

**Recursive-component detection** (spec §48): transitive closure of `dep_pos`
restricted to one stratum, then `recursive_p(p) = closure[p, p]`. This is ~15
lines and lets non-recursive rules skip the delta loop, so it is worth doing in
v1 rather than treating every stratum as recursive.

---

## 8. Evaluation

### 8.1 Join strategy — recursive nested loop

**Deliberate deviation from spec §28–29.** The spec proposes materialised binding
sets with numeric binding ids (`bind_set[b, var]`, current/next collections). A
recursive nested-loop join over one binding environment is substantially smaller
and allocation-free:

```awk
function join(r, order_n, pos, ...) {
    if (pos > order_n) { emit_head(r); return }
    i = plan[pos]                       # literal index in chosen order
    kind = rule_lit_kind[r, i]
    if (kind == 3) { if (eval_compare(r, i)) join(r, order_n, pos + 1); return }
    if (kind == 2) { if (eval_negation(r, i)) join(r, order_n, pos + 1); return }
    for (n = 1; n <= scan_count; n++) {         # full relation, or delta
        t = scan_tuple(n)
        if (match_tuple(r, i, t)) {             # binds unbound args, checks bound
            join(r, order_n, pos + 1)
            unbind(r, i)                        # undo this literal's bindings
        }
    }
}
```

Bindings live in `bind_has[]`/`bind_val[]`; `match_tuple` records which slots it
bound (in a per-depth scratch array keyed by `pos`) so `unbind` can revert them.
Recursion depth = body length (single digits), well inside every target awk.
This removes the binding-id tables, the current/next copies, and the aggressive
`array_clear` discipline of spec §68 — the one `array_clear` helper is still
provided for the delta arrays, since whole-array `delete` is not POSIX.

`match_tuple` is the spec §30 rule: unbound arg → bind; bound arg or constant →
compare encoded values. No general unification.

`eval_negation` needs all args bound (guaranteed by §6), so it builds the key and
does one `in` test — no relation scan (spec §49).

`eval_compare`: `=`/`!=` compare encoded values, so `foo`, `"foo"`, and `42` are
pairwise distinct across types (document this). Ordering operators require both
operands to be `n:`-encoded; a non-numeric operand at runtime is a fatal error
citing the rule's source location rather than a silent failure, because a silent
failure is indistinguishable from "no such fact".

### 8.2 Body reordering (spec §35)

Planned per rule *invocation* (once per rule per iteration — not in the inner
loop), so relation sizes are current:

1. Start with no variables bound; if a delta position is designated, that literal
   is placed first (its relation is smallest and it must participate).
2. Repeatedly: emit every comparison and negative literal whose variables are all
   bound; then pick the remaining positive literal with (a) most already-bound
   variables, (b) smallest `pred_tuple_count`, (c) lowest source position.

The tie-break chain makes the plan deterministic, so a given program+dataset
always evaluates in the same order — important for reproducible `-v` traces and
for the differential tests.

### 8.3 Strata and semi-naive fixpoint (spec §39–47)

```text
for s = 0 .. max_stratum:
    # seed pass: every rule with head in stratum s, full relations
    for each rule r in stratum s:  eval_rule(r, delta_pos = 0)

    # delta seed: full current contents of recursive predicates in s (spec §43)
    delta_seed(s)

    # fixpoint
    while any delta non-empty:
        for each rule r in stratum s with >= 1 same-stratum positive literal:
            for each such literal position d:
                eval_rule(r, delta_pos = d)      # d scans delta, others scan all
        delta_rotate()                            # next_delta -> delta
        stat_iterations++
```

`eval_rule(r, 0)` means "scan full relations everywhere" — so the naive engine
(spec §40/§74) is the same code with the delta loop replaced by "re-run all rules
in the stratum until nothing is added". The two engines therefore share
`eval_rule`, `join`, `match_tuple`, and `emit_head`; naive mode costs ~15 extra
lines and is the correctness oracle for spec §76.

Seeding deltas with the *entire* current contents of recursive predicates
(spec §43) re-derives some tuples in the first delta round; dedup absorbs them
and it removes a whole class of "missed derivation from a pre-existing fact"
bugs (e.g. a predicate that has both explicit facts and rules).

Lower strata are frozen while a higher stratum runs, which is what makes
negation sound (spec §39) — enforced structurally: `emit_head` asserts the head
predicate's stratum equals the stratum being evaluated.

---

## 9. Queries and output

Queries run after the fixpoint, in source order, command-line queries after
embedded ones (spec §52–54). A query is evaluated with the same `join`; instead
of `emit_head` inserting a tuple, the leaf emits a row.

- Duplicate rows are suppressed with a `seen[]` hash cleared per query (two
  bindings of anonymous variables can yield the same projected row).
- Arity 0 / fully ground query: short-circuit on the first solution, print
  `true` or `false` (spec §15).
- Columns = named variables in order of first appearance; anonymous variables are
  never printed.
- Formats (spec §60–62): `text` (bare symbols/numbers; strings bare unless they
  contain whitespace, a quote, or are empty, else `"…"` with escapes), `csv`
  (RFC 4180: double the quotes, quote on `, " CR LF` or leading/trailing space),
  `tsv` (documented escaping: `\\`, `\t`, `\n`, `\r`). The README states these as
  the stable formats (spec §62's "documented is better than conventional").
- Blank line between query result blocks when more than one query runs, so
  multiple `-q` outputs stay distinguishable.

**Sorting (`-s`).** Implemented in the core by piping each query's rows through
`"sort"` and `close()`ing it before the next query — not once over the whole
output as spec §63 suggests. Same portability story (POSIX `sort`, no `asort()`),
but it keeps per-query grouping correct when several queries run. The wrapper
sets `LC_ALL=C` for byte-deterministic order.

---

## 10. CLI, wrapper, REPL

```text
awklog [-cinsv] [-D mode] [-F format] [-q query] [file ...]
    -c  check only          -n  suppress output        -s  sort output
    -i  REPL after eval     -v  verbose (repeatable)   -h  usage
    -q query (repeatable)   -F text|csv|tsv            -D naive|semi (default semi)
```

The wrapper is POSIX `sh` + `getopts`, and passes settings **through the
environment, not `-v`**: `awk -v x=…` performs escape-sequence processing on the
value, which would corrupt a query containing `\n` inside a string literal.
`awklog.awk` reads `ENVIRON["AWKLOG_QUERY"]`, `AWKLOG_FORMAT`, `AWKLOG_SORT`,
`AWKLOG_MODE`, `AWKLOG_VERBOSE`, `AWKLOG_CHECK`, `AWKLOG_QUIET`,
`AWKLOG_INTERACTIVE`, `AWKLOG_STDERR`, `AWKLOG_PROMPT` (`ENVIRON` is POSIX awk
and present on every target), and lets an explicit `-v awklog_*` override it so
direct `awk -f awklog.awk` use stays ergonomic (spec §58).

Multiple `-q` values are concatenated with newlines into `AWKLOG_QUERY` and lexed
as a mini-program in which every statement must be a query — no private separator
needed, since the parser already handles a statement stream.

Interpreter location: `AWKLOG_AWK` env override → install-time libexec path →
`dirname $0`/awklog.awk (so the repo checkout runs without installing).
The wrapper `exec`s awk, preserving its exit status (spec §65), and detects a tty
with `[ -t 0 ]` to decide whether the REPL prints a prompt.

**REPL** (spec §59) reads with `getline line < AWKLOG_STDIN` (default
`/dev/stdin`), accepts one statement per line plus `.help`, `.stats`, `.quit`;
`.dump` (undocumented) prints every relation for differential testing. A syntax
error inside the REPL reports and continues instead of exiting — the only place
`die()` must not be used, so parse errors route through a `parse_fatal` flag the
REPL can catch. v1 accepts **queries and dot-commands only**; fact/rule insertion
is future work (spec §89) because it would require re-stratifying and
re-evaluating.

**Statistics** (spec §66–67): `stat_input_facts`, `stat_derived_facts`,
`stat_rules`, `stat_predicates`, `stat_rule_runs`, `stat_tuple_scans`,
`stat_iterations`, printed only by `.stats` or `-v` (never by default).

---

## 11. Milestones

Each milestone ends with a runnable artifact and its own tests; nothing is
"finished" until `tests/run.sh` is green under every awk installed.

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Skeleton: `awklog` wrapper, `awklog.awk` stub, `tests/run.sh`, LICENSE | `awklog -h` prints usage, exits 0; harness runs 0 cases |
| M1 | Lexer + parser + diagnostics | Every construct in spec §17 parses; `-c` reports `file:line:col:` errors for a dozen malformed inputs |
| M2 | Predicate/tuple tables, value encoding, fact loading | `-c -v` reports correct predicate/fact counts; duplicate facts collapse; `SUBSEP`/`CONVFMT` hazard tests pass |
| M3 | Safety checks, dependency graph, stratification | spec §32/33/34/50 invalid rules rejected with location; spec §12 negative cycle rejected; strata match spec §12 example |
| M4 | Naive evaluator + queries + text output | spec §4, §78, §79, §80, §81 examples produce the documented output end to end |
| M5 | Semi-naive engine + differential tests | `-D naive` and `-D semi` produce identical `.dump` for every case; `stat_iterations`/`stat_tuple_scans` show the expected reduction on `path/2` |
| M6 | csv/tsv, `-s`, `-n`, `-i` REPL, `.stats` | Format and REPL cases pass; quoting cases (comma, embedded quote, tab, newline) pass |
| M7 | Docs + examples + portability sweep | README (incl. the numeric-precision caveat of spec §7.3 and the reserved word `not`), 3 examples, green under BWK awk, mawk, gawk, gawk --posix |
| M8 | Random differential testing + size trim | `tests/gen.awk` runs ≥500 generated programs with zero naive/semi divergence; final line count inside 700–1,200 |

Recommended order within M1–M5 is strict: nothing downstream can be trusted while
the parser or the safety checker is incomplete, and the naive engine (M4) must
exist before the semi-naive one (M5) so M5 has an oracle from day one.

---

## 12. Testing

`tests/run.sh` (POSIX sh, no bashisms) iterates `tests/cases/*.dl`:

```text
NAME.dl        program (may contain embedded queries)
NAME.args      optional extra CLI args (default: -s)
NAME.out       expected stdout   (byte-exact)
NAME.err       optional expected stderr, matched as a substring/pattern
NAME.status    optional expected exit status (default 0)
```

Run modes: each case is executed under `-D semi` and `-D naive`, and both must
match `NAME.out`; cases are also run with `AWK=` each of `awk`, `mawk`, `gawk`,
`gawk --posix` when present. Differential mode additionally compares `.dump`
output of both engines (spec §76).

Coverage checklist, one case minimum each (spec §75): simple facts; single rule;
multiple rules; recursive path; cyclic graph recursion; mutual recursion;
duplicate facts; anonymous variables (including `pair(_, _)` not forcing
equality); strings with escapes, commas, tabs, quotes; integers incl. negative
and large; all six comparison operators; type-distinct `=` (`foo` vs `"foo"` vs
`42`); safe negation; multiple strata; zero-arity predicates; ground queries
true and false; multi-variable queries; multiple `-q`; each output format;
`-c`; `-n`; unsafe head variable; unsafe negated variable; unsafe comparison;
negative recursion rejection; syntax errors at line/column; undefined predicate
warning; REPL script via stdin.

`tests/gen.awk` emits random *safe* programs (facts, non-recursive rules,
recursive rules, stratified negation) with a seed argument so a failure is
reproducible from its seed; the driver compares engines, not expected output.

---

## 13. Portability rules (enforced by review, spec §69–70)

Forbidden: `asort`/`asorti`, `gensub`, `PROCINFO`, arrays of arrays, `@namespace`,
`typeof`, `switch`, indirect function calls, `delete whole_array`, `length(array)`,
`RS` as a regex, `\s`-class regex shorthands, `--` in `getopts`-hostile places.
Required: `a[x, y]` with `SUBSEP`; `array_clear()` helper; `(k in a)` for
membership; `sprintf("%d", …)` for integer text; `substr`/`index` for lexing;
explicit `CONVFMT`/`OFMT`.

`/dev/stderr` and `/dev/stdin` are used but are injectable
(`AWKLOG_STDERR`, `AWKLOG_STDIN`) for hosts lacking them (spec §64).

Local gap: this machine has only BWK awk 20200816. `brew install mawk gawk` is a
prerequisite for M7's portability sweep; until then the matrix is unverified and
the plan treats that as an open risk, not a passed criterion.

---

## 14. Deliberate deviations from the spec

1. **Recursive nested-loop join** instead of materialised binding sets
   (§8.1 above vs. spec §28–29) — less code, no binding tables, same semantics.
2. **Line-array cursor** in the lexer instead of one concatenated buffer
   (spec §19) — free `line:col` diagnostics.
3. **`-s` implemented in the core**, piping each query through `sort`, instead of
   the wrapper sorting all output (spec §63) — preserves per-query grouping.
4. **Options passed via `ENVIRON`**, not `-v` (spec §57) — avoids `-v` escape
   processing corrupting query text.
5. **Recursive-component detection in v1** rather than treating each stratum as
   wholly recursive (spec §48 allows either) — ~15 lines, avoids needless
   fixpoint iteration over non-recursive rules.
6. **Undefined predicate = empty relation + stderr warning**, a case the spec
   leaves open.
7. **Runtime type error** (not silent failure) when an ordering comparison gets a
   non-numeric operand — the spec says such comparisons are "legal only when both
   resolve to numeric" without saying what happens otherwise.

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| `CONVFMT` turning large integers into `1e+06` inside keys | `sprintf("%d", …)` in `value_encode`; explicit test with `1000000` |
| `SUBSEP` byte inside a string literal forging tuple keys | escape `\` and `SUBSEP` when encoding; explicit test |
| Array autovivification from `if (a[k])` membership tests | use `(k in a)` everywhere; grep for `\[[^]]*\])\s*[){]` patterns in review |
| Line budget overrun (spec §88.11) | per-group budget in §3, checked at each milestone; naive engine shares `eval_rule` |
| `exit` semantics differing between main rule and `END` | all stages run in `END`; `die()` only called from there |
| REPL input source clashing with a program read from stdin | `AWKLOG_STDIN` injectable; document that `-i` with a stdin program is unsupported |
| Portability unverified without mawk/gawk installed | install both before M7; treat M7 as blocked until then |
| Deep recursion in `join` on a long rule body | depth = body length; document a practical limit and test a 12-literal body |

---

## 16. Success criteria (spec §88, restated as checks)

1. Green `tests/run.sh` under BWK awk, macOS awk, mawk, gawk, and `gawk --posix`.
2. No forbidden construct from §13 present (grep-checkable).
3. All spec §17 grammar forms parse, including zero-arity predicates.
4. Recursion, mutual recursion, and cyclic graphs terminate with correct results.
5. Semi-naive deltas demonstrably reduce `stat_tuple_scans` vs. naive on `path/2`.
6. Safe stratified negation works; recursion through negation is rejected.
7. Variables, symbols, strings, integers, and all six comparisons supported.
8. Embedded and `-q` queries both work; ground queries print `true`/`false`.
9. Naive and semi-naive agree on every test case and every generated program.
10. 700–1,200 lines of readable AWK, no code golf (spec §87).
11. `awklog -h` and `awklog file.dl` are enough for a new user.
