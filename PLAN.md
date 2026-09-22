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

**Actuals at M1** (lexer, parser and diagnostics landed): lexer 211 lines against
130, parser 253 against 180 — both over, the lexer past the 50%-over gate stated
above. Most of the excess is four helpers the budget did not anticipate
(`lex_skip_space`, `lex_span`, `lex_line_end`, `lex_word_kind`): they exist
because bytes are classified with `index()` over explicit alphabets rather than
regex ranges (§14.9) and because the EOF token carries a source location. The
budget numbers are left as they stand rather than raised to fit: at ~740 lines
with the checker, evaluator, output and REPL still unwritten, the 1,200-line cap
in §16 is the live risk, and M8's size trim now has a measured starting point.

**Actuals at M3** (safety checks, dependency graph, stratification landed):
checks 124 lines against 100, graph and strata 124 against 90. The checks group
carries two things the budget did not list — the undefined-predicate warning
of §6 and the static rejection of an ordering comparison against a non-numeric
constant — plus `rule_noun`/`var_display`, which exist so that one diagnostic
serves rules and queries alike. The graph group is over because naming a
predicate that is genuinely on a negative cycle needs a second closure
(`negative_cycle_pred`) beyond the one `recursive_p` wanted; sharing
`closure()` between them paid back about a third of it. Total is 1,094 lines
with the evaluator, query layer, output and REPL still to come, so the
1,200-line cap will not survive M4–M6 as written: M8's trim is now
load-bearing rather than cosmetic, and the lexer and parser remain the two
groups furthest over budget in absolute lines.

**Actuals at M4** (naive evaluator, queries and text output landed): 396 lines
against the 340 budgeted across the three groups it fills. Query 58 against 80
and output 61 against 90 are both under; the whole overrun sits in evaluation,
277 lines against 170, and 86 of those are the body planner (`plan_rule` and
its three helpers). §8.2 specifies reordering, but the budget row for the group
lists no function for it, so that row was short by a planner from the start.
The file is now 1,520 lines, past the 1,200 cap with M5 and M6 still to come,
which settles what the M3 note left open: M8's trim is a required milestone
rather than a polish, and the groups to take it from are, in absolute excess,
the parser (253 against 180), the lexer (211 against 130), the evaluation
planner, and the checks (124 against 100). `make count` reports the number
but exits 0 whatever it is, so the budget is documentation and not a gate;
M8 should make it exit non-zero outside the band, which cannot happen earlier
without making the commit gate red by design for M4-M7.

**Actuals at M5** (semi-naive engine and differential tests landed): the
evaluation and semi-naive groups now measure 445 lines together against the
240 budgeted for the pair, up from 280 at M4. Of the 165 lines added, 145 are
the stratum drivers and the delta machinery — `eval_stratum`, `stratum_rule`,
`eval_naive`, `eval_semi`, `delta_scanned`, `delta_next_pos`, `delta_seed`,
`delta_rotate` — and the rest is the delta position threaded through
`eval_rule`, `plan_rule`, `join` and `emit_head`. The budget's `delta_round`
never materialised: a round is four lines inside `eval_semi`. What the budget
did not anticipate is that the delta loop needs two selections the naive
engine does not — which rules to re-run and which body position to designate
— and `delta_scanned` and `delta_next_pos` answer those in 17 and 10 lines of
code, so the overrun is comment and structure rather than an algorithm that
outgrew its row. `dump_relations` (38 lines, inside the REPL group's 110) arrived at M5
rather than M6 because M5's exit criterion is stated over `.dump`; the query
group grew from 58 to 80 for `query_print`, which the dump needs and which
M6's `-n` will reuse.

The file is 1,758 lines, 558 over the cap, and the ranking of groups by
absolute excess is now evaluation (445 against 240), parser (253 against
180), lexer (211 against 130) and checks (124 against 100). M8's trim has no
slack left to find outside those four.

M4 also refuses `-F csv`, `-F tsv`, `-s`, `-n` and `-i` with a usage error
instead of accepting and ignoring them. Before queries printed anything the
difference was invisible; now an ignored `-F csv` would answer a documented
request with text, and an ignored `-s` with unsorted rows. M6 replaces each
refusal with the implementation, and `tests/run.sh` correspondingly passes no
arguments by default rather than `-s`, so a case that prints rows pins the
order the evaluator produces them in.

**Actuals at M6** (the csv and tsv formats, `-s`, `-n`, the REPL and
`.stats` landed): output 123 lines against 90 and query 141 against 80, both
modest — the formats cost two quoters, and text and tsv share `escape_text`,
which pays for one of them; the query group grew by `row_print`,
`rows_flush` and `sort_close`, the per-query `sort(1)` pipe of §14.3 and the
check that it ran. The REPL group is the
one that was mis-sized rather than merely overrun: the budget's 110 lines
cover `repl`, `repl_command`, `print_stats` and `dump_relations`, and what
v1 actually needs is those plus `repl_query` — parse, safety-check, answer,
forget — and `repl_forget_preds`, which is what "forget" means. Together
they are 78 of the group's 258 lines (188 REPL, 42 dump, 28 statistics), and
nothing else in the file could have supplied them, because nothing else has
a reason to undo a predicate.

Undoing one is the price of the rule in §10 that a session cannot change the
model: a mistyped query still interns every name it mentions, and leaving
those behind would have the next `.stats` and `.dump` describe the typing
rather than the program. Predicate ids are handed out in sequence and reused
after a rollback, so every table keyed by one is rolled back together — a
surviving `pred_undefined` entry would silence a warning belonging to a
different predicate. Rules are *not* rolled back for the mirror-image
reason: `rule_new()` does not clear `rule_var_slot`, so a reused rule index
would come with the previous statement's variables.

The file is 2,191 lines, 991 over the cap. The ranking by absolute excess is
evaluation (452 against 240), parser (273 against 180), lexer (234 against
130) and then the REPL group (258 against 110), with the source-collection
group now 54 lines against 20 for `args_are_stdin()`; M8 has one milestone's
worth of code left to add and all of that to take out.

---

## 4. Data representation

Flat 1-D and 2-D associative arrays only; `a[x, y]`, never `a[x][y]` (spec §69).

```awk
# source
src_n; src_text[i]; src_file[i]; src_fnr[i]

# lexer state (globals, not return values)
lex_i; lex_col                 # cursor: source line index, 1-based column
lex_end_ln; lex_end_col        # where the source ran out, so EOF has a location
tok_kind; tok_text; tok_ln; tok_col     # current token
pk_kind; pk_text; pk_ln; pk_col         # lookahead, valid while have_peek
have_peek

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
rule_lit_line[r, i]; rule_lit_col[r, i] # for per-literal diagnostics
rule_lit_rhs_ln[r, i]; rule_lit_rhs_col[r, i]  # comparison right operand
rule_is_fact[r]; rule_is_query[r]       # a fact is a rule with an empty body
query_n; query_rule[q]                  # queries in run order: source, then -q

# bindings (single environment, undone on backtrack — see §6)
bind_has[slot]; bind_val[slot]

# deltas
delta_t[p, n]; delta_n[p]; next_t[p, n]; next_n[p]
```

### Value encoding (spec §26)

`s:` symbol, `q:` string, `n:` number — the *encoded* form is what the engine
compares, hashes, and stores; decoding happens only in output.

Two hazards the spec does not name, both must be handled in `value_encode`:

1. **Numeric stringification.** Build numbers with `sprintf("%d", v)` when
   `v == int(v) && abs(v) < 2^53`, else `sprintf("%.17g", v)`, because above
   2^53 a host's `%d` may convert through an integer type that cannot hold the
   value, while `%.17g` round-trips a double exactly. *(An earlier revision
   justified this by `CONVFMT`: `"" x` supposedly rendering `1000000` as
   `1e+06`. POSIX converts an integral value with `%d` and consults `CONVFMT`
   only for the rest, and measurement agrees — under `CONVFMT = "%.6g"`, BWK
   awk, mawk, gawk and `gawk --posix` all print `1000000` and
   `100000000000000000` as digits. `CONVFMT = OFMT = "%.17g"` in `init()` stays
   as belt and braces for any non-integral value that ever reaches it, but no
   test can pin it while the language has integer literals only.)*
2. **`SUBSEP` collisions.** Tuple keys join encoded values with `SUBSEP` (`\034`).
   A string literal containing `\034` could forge another tuple's key. In
   `value_encode`, escape `\` as `\\` and `SUBSEP` as `\S`, making key
   construction injective. Done with an `index`/`substr` loop, not `gsub`: POSIX
   leaves a backslash in a `gsub` replacement outside `\&` and `\\` undefined.
   Cost: one scan per string constant, skipped entirely when it holds neither
   byte, and once at parse in any case.

### Deduplication (spec §25)

`tuple_add(p, n, argv)` takes the encoded arguments in an array (callers have
them in separate places — head terms at load time, bindings in the evaluator —
so packing them into one string first would cost a scan per candidate row),
builds the key, returns the tuple id and sets a global `tuple_added` to 1/0
(AWK has no multiple return values). Membership tests
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
falls under the comparison rule with no special case. An ordering comparison is
rejected at check time as soon as *either* operand is a non-numeric constant,
which is stricter than rejecting only the both-constant case and is sound for
the same reason: spec §13 makes such a comparison legal only where both
operands resolve to numeric, and a symbol or string constant never will.
Nothing is constant-folded — an always-true or always-false comparison between
two constants is simply evaluated, which costs one comparison per candidate row
and no lines of code.

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
negation` (spec §38), naming a predicate on the cycle. The predicate that
tripped the bound is *not* that predicate: everything standing above a cycle
climbs with it, and the higher a predicate sits the sooner it crosses, so the
tripped one is usually innocent. `negative_cycle_pred()` instead closes the
combined positive/negative edge set and returns the lowest-numbered `p` with a
negative edge to some `q` that leads back to `p` — a cycle through negation by
definition, and deterministic.

Convergence is O(P³) worst case with P predicates — fine at the intended scale
(spec §36), and it avoids an SCC implementation entirely.

The relaxation computes the *minimal* stratum assignment, which is not always
the one the spec's prose illustrates: for spec §12's example it yields
`depends, unfinished, todo, blocked = 0` and `ready = 1`, where §12 lists
`blocked = 1` and `ready = 2`. Both are valid stratifications — §12 says "can
be arranged as" — and the numbering has no effect on results, since all that
evaluation needs is that a negated predicate is complete before the stratum
that negates it runs. `tests/cases/strat-example.dl` pins the computed
numbering and says why it differs.

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
REPL can catch. The catch turns `die()` into a function that *returns*, and
every loop an error can be raised inside has to be able to leave: the lexer's
token functions answer `EOF` from that point on, which drains every parser
loop, but `lex_string()` scans bytes below that level and needs an explicit
`break` at each of its three error sites — without one it re-reads the same
byte for ever. `parse_statement()` records what a statement defines
(`pred_has_fact`, `pred_has_rule`, `stat_rules`) only once the statement has
been accepted, for the same reason: past a caught `die()`, execution is still
there to reach that code, and a rejected assertion must leave nothing behind.

`-c` and `-i` are refused together rather than resolved silently in `-c`'s
favour: `-c` stops before evaluation and the REPL answers against what
evaluation produced. `-i` on a program read from standard input is refused
too — the program would have consumed the session before the first prompt.
The wrapper catches the no-operand spelling and `awklog.awk` re-checks in
`END`, reading `ARGV` rather than what arrived: an empty program arrives as
no record at all and would arm nothing, and `-i` would then exit 0 in
silence, which is the fault the guard exists to stop. Diagnostics still have
to name standard input under all three of its spellings, or they read
differently depending on the host: BWK awk leaves `FILENAME` empty, mawk and
gawk set it to `-`, and `awklog -i /dev/stdin` names the same stream a third
way. Both checks run after the `-c`/`-i` one, in the wrapper and in
`awklog.awk` alike, so the two paths name the same fault first. An injected `AWKLOG_STDIN` puts the session on another
descriptor and lifts the refusal in both places, which is what that variable
is for; the wrapper then asks *it*, not its own stdin, whether to print a
prompt.

A line is trimmed of `\r` as well as blanks before a dot command is matched,
because `lex_skip_space()` counts `\r` as whitespace: a session piped from a
CRLF file would otherwise parse its queries and then recognise no command at
all, `.quit` included, and run on past the end of what was typed.

`stat_tuple_scans` is restored across a REPL statement along with the
predicate table: `join()` counts a query's scans as it counts a rule's, and
`.stats` is supposed to describe the program that was loaded rather than the
typing that went after it.

A line typed at the prompt is labelled `<repl>` rather than `<stdin>`, and
numbered from 1 in its own right. The two can coexist — `AWKLOG_STDIN` puts
the session on one descriptor while the program arrives on another — and two
diagnostics both reading `<stdin>:3` would point at different text.

The prompt goes to `STDERR`, with `.help` and `.stats` and for the same
reason: stdout carries rows, so `awklog -i prog.dl > rows.txt` from a
terminal gets rows and nothing else. Each round of the loop flushes stdout
before printing the next prompt, because awk block-buffers it when it is not
a terminal and `awklog -i prog.dl | tee log` — stdin still the terminal —
would otherwise answer nothing until the session ended. `STDERR` is flushed
only where the prompt has just opened it for writing; asking awk to flush a
file it never opened is not portable. The newline that closes the last
prompt's line belongs to the end-of-input path alone: `.quit` arrived with an
Enter that ended the line already. v1 accepts **queries and dot-commands only**; fact/rule insertion
is future work (spec §89) because it would require re-stratifying and
re-evaluating.

**Statistics** (spec §66–67): `stat_input_facts` (distinct rows, with the
collapsed duplicates counted separately in `stat_dup_facts`), `stat_derived_facts`,
`stat_rules`, `stat_predicates`, `stat_rule_runs`, `stat_tuple_scans`,
`stat_iterations`, printed only by `.stats` or `-v` (never by default). A second
`-v` adds one line per predicate with its relation size, which is the only way
to see a stratum's shape before the query layer exists.

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
| M5 | Semi-naive engine + differential tests | `-D naive` and `-D semi` produce identical `.dump` for every case; `stat_tuple_scans` shows the expected reduction on `path/2` (see the note below on `stat_iterations`, which does not) |
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
NAME.args      optional extra CLI args (default: none)
NAME.in        optional stdin, which -i reads (default: /dev/null)
NAME.env       optional sh, sourced around the run (AWKLOG_* with no option)
NAME.nodump    present when the case legitimately dumps no relations
NAME.out       expected stdout   (byte-exact)
NAME.err       optional expected stderr, matched as a substring/pattern
NAME.status    optional expected exit status (default 0)
```

Run modes: each case is executed under `-D semi` and `-D naive`, and both must
match `NAME.out`; cases are also run with `AWK=` each of `awk`, `mawk`, `gawk`,
`gawk --posix` when present. Each case is then run once more per awk with
`AWKLOG_DUMP=1` under each engine, and the two dumps must be byte-identical
(spec §76) — that compares the whole model rather than only the rows the
case's queries ask for, and it is what catches a delta the fixpoint forgot to
maintain. `AWKLOG_DUMP` is an undocumented environment hook, absent from the
wrapper, that prints what M6's `.dump` will print: one line per predicate
carrying its size, then one per row, everything through `sort(1)` because the
two engines insert in different orders, with each value tagged by its type
letter and quoted so that `foo`, `"foo"` and a value holding a newline stay
distinct and stay on one line. The hook also suppresses the queries' own
rows, which are *not* sorted and whose order within a relation is an engine
artefact — mixing them in would report a divergence for two engines that
agree on the whole model. `diff_case` additionally requires the two exit
statuses to match each other and the case's `NAME.status`, and a case that
exits 0 to have dumped something, so that a case which starts dying for an
unrelated reason loses its differential coverage loudly rather than quietly.

That per-engine row order is also a live constraint on `NAME.out`, which is
compared byte-exactly against *both* engines: a case whose rows the two reach
in different orders cannot be written that way, and must either pin one
engine in `NAME.args` (as `eval-semi-scans` and `eval-naive-scans` do) or, in
a case about something other than order, pass `-s`, which since M6 sorts each
query's rows and so makes the order the same for both. The engines' agreement
on the model is `diff_case`'s job, not `NAME.out`'s.

Standard input is redirected for every case, from `NAME.in` when there is one
and from `/dev/null` otherwise, so that a `-i` case reads only what it is
given and a case without `-i` cannot reach the harness's own stdin. `NAME.env`
is sourced in a subshell around the run, which is how `repl-prompt` sets
`AWKLOG_PROMPT`: the wrapper otherwise decides the prompt from whether stdin
is a terminal, and a harness has none to offer, so without it the prompt path
would go untested.

Coverage checklist, one case minimum each (spec §75): simple facts; single rule;
multiple rules; recursive path; cyclic graph recursion; mutual recursion;
duplicate facts; anonymous variables (including `pair(_, _)` not forcing
equality); strings with escapes, commas, tabs, quotes; integers incl. negative
and large; all six comparison operators; type-distinct `=` (`foo` vs `"foo"` vs
`42`); safe negation; multiple strata; zero-arity predicates; ground queries
true and false; multi-variable queries; multiple `-q`; each output format;
`-c`; `-n`; unsafe head variable; unsafe negated variable; unsafe comparison;
negative recursion rejection; syntax errors at line/column; undefined predicate
warning; REPL script via stdin; semi-naive equivalence (spec §75) — which the
whole-suite dump comparison gives for every case, plus the three shapes that
comparison would otherwise only catch by luck: a recursive predicate carrying
its own facts, a non-recursive rule reading a relation that grows under it,
and a rule with two recursive literals (spec §45).

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

`fflush()` is used, once, in `dump_relations`, and is the one function here
outside POSIX Issue 7 awk (Issue 8 adds it). Rows leave through `sort`'s
stdout rather than awk's, so anything already printed has to be pushed out
first or it can land after them. All four awks in the matrix have `fflush()`
and, measured, all four also flush at the pipe without being asked — the call
is what makes that a guarantee rather than an observation. `-s` uses it for
the same reason and for one more: its rows leave through `sort` while the
blank line separating one query's block from the next leaves through awk, so
without the flush the separator can overtake the block it separates.

`close()` on the REPL's input is **not** used, and the omission is
load-bearing: mawk 1.3.4 (20260302) segfaults on `close("/dev/stdin")` once
`getline` has read from it, reproducibly and in four lines outside awklog.
Nothing needs the close — the REPL is the last thing that runs — so the
portable choice and the correct one coincide.

`/dev/stderr` and `/dev/stdin` are used but are injectable
(`AWKLOG_STDERR`, `AWKLOG_STDIN`) for hosts lacking them (spec §64).

mawk's `getline < "/dev/stdin"` does not return a line until its read buffer
fills or the stream ends, so a REPL driven through a *fifo* under mawk
answers nothing until the writer closes. Measured, this is mawk's own
behaviour and reproducible in one line outside awklog; on a pty — the case
the prompt exists for — mawk answers immediately, like BWK awk and gawk. Left
alone rather than worked around: the fix would be to read stdin in the main
rule, which would mean the program and the session sharing one descriptor,
which is the arrangement both the wrapper and `awklog.awk` refuse.

Local matrix: BWK awk 20200816 (`/usr/bin/awk`), mawk 1.3.4, gawk 5.4.1, and
`gawk --posix` are all installed, so `tests/run.sh` exercises the full sweep on
every run and M7 is not blocked on tooling.

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
8. **`-n` does not silence the REPL.** The spec gives `-n` as "suppress
   normal output" and says nothing about `-i`; taken literally the two
   together would leave a prompt that never answers. `-n` therefore covers
   the program's own queries — the embedded ones and `-q` — and the REPL
   prints regardless, which makes `-i -n` the useful combination "load
   quietly, then ask". The `-h` text says so, and `repl-quiet` pins it.
9. **Byte classification with `index()` over explicit alphabets** in the lexer,
   instead of scanning tokens with `match()`. POSIX `match()` takes no start
   offset, so scanning from column *n* means `substr(line, n)` — copying the
   rest of the line for every token. Measured on 20,000 facts: `match()` is
   ~18% faster and ~16 lines shorter when each fact is on its own line, but on
   a single 300 KB line it takes 121 s under BWK awk against 8.3 s for the
   character loop (mawk: 0.68 s against 0.26 s). The cliff is not worth the
   lines. *(An earlier revision justified this by the locale-dependence of
   `[A-Za-z]` ranges; that was tested under `en_US.UTF-8`, `cs_CZ.UTF-8` and
   `da_DK.UTF-8` on all four awks and does not happen — only `[[:alpha:]]` is
   locale-sensitive there, and nothing here uses it.)*

---

## 15. Risks

| Risk | Mitigation |
|---|---|
| A host spelling a large integer in exponent form inside a key | `number_text()` picks `%d` below 2^53 and `%.17g` above; the `fact-numbers` case pins both branches as injective. `CONVFMT` itself turned out not to be the hazard — see §4 |
| `SUBSEP` byte inside a string literal forging tuple keys | escape `\` and `SUBSEP` when encoding; explicit test |
| Array autovivification from `if (a[k])` membership tests | use `(k in a)` everywhere; grep for `\[[^]]*\])\s*[){]` patterns in review |
| Line budget overrun (spec §88.11) | per-group budget in §3, checked at each milestone; naive engine shares `eval_rule` |
| `exit` semantics differing between main rule and `END` | all stages run in `END`; `die()` only called from there |
| REPL input source clashing with a program read from stdin | the wrapper refuses `-i` with no file operand outright, since the program would have consumed the session before the first prompt; `AWKLOG_STDIN` stays injectable for a caller that wants the two on different descriptors |
| `sort(1)` missing or failing under `-s` | rows leave through its stdout, so a failed pipe would print nothing and exit 0, which a pipeline reads as "no rows matched". `rows_flush()` and `dump_relations()` check `close()` and die instead. Measured, only mawk and gawk report a failed pipe there (127); BWK awk and `gawk --posix` return 0 — but all four return 0 on success, so the check never fires wrongly and catches it where it can. The same measurement is why the check may only be applied to a pipe that was written to: `close()` of a command never opened returns −1 on all four, and a program with no predicates opens none, so `dump_relations()` returns before the pipe (`repl-dump-empty`). A status meaning SIGPIPE is exempt as well: `awklog -s f.dl \| head` kills `sort` once the reader has what it wants, and mawk and gawk report that here as 269, which taken for a failure would make an ordinary pipeline exit 1 — intermittently, since it depends on which end stops first |
| The wrapper's prompt probe opening `AWKLOG_STDIN` | a fifo is the natural way to drive a session from another process, and opening one to ask `[ -t 0 ]` would block the wrapper until a writer arrived and then close it, leaving awk's own open with no writer. The probe runs only under `-i`, and only against a path already known to be a character device |
| A long `-i` session growing without bound | each statement costs one source line and one rule's term and variable entries, never reclaimed: predicates are rolled back but rules are not, because `rule_new()` does not clear `rule_var_slot` and a reused index would inherit the previous statement's variables. A few hundred bytes a statement, so a session would have to run to tens of thousands of queries to matter. Recorded rather than half-fixed in v1: reclaiming a rule means deleting its `rule_var_slot` entries by name first, and the source line has to outlive the parse that reads it |
| `-s` and a csv value containing a newline | RFC 4180 spells such a value across lines, and `sort(1)` sorts lines, so the two cannot both be honoured. Escaping the newline would stop being RFC 4180, and refusing `-s` for csv outright would cost every result that holds none, which is nearly all of them — so the combination is allowed and `row_print()` warns once, on the first row it actually damages. `out-csv-sort` pins the warning and the damage; tsv, which escapes, has no such hole |
| A portability break slipping in between sweeps | all four awks are installed locally; `tests/run.sh` runs every case under each of them, so the sweep is continuous rather than an M7 event |
| Deep recursion in `join` on a long rule body | depth = body length; document a practical limit and test a 12-literal body |
| BWK awk string ops are O(length) — `substr` and passing a string to a function both cost time proportional to the whole string, at any offset (mawk and gawk are O(1)) | inherent to that awk, so any lexer is quadratic in the length of one line: 20,000 facts cost 0.5 s spread one per line but 8.3 s on a single line. Irrelevant for sources with one statement per line; documented rather than worked around, since avoiding the copy recovers only 28% and smears `src_text[lex_i]` through every call site |

---

## 16. Success criteria (spec §88, restated as checks)

1. Green `tests/run.sh` under BWK awk, macOS awk, mawk, gawk, and `gawk --posix`.
2. No forbidden construct from §13 present (grep-checkable).
3. All spec §17 grammar forms parse, including zero-arity predicates.
4. Recursion, mutual recursion, and cyclic graphs terminate with correct results.
5. Semi-naive deltas demonstrably reduce `stat_tuple_scans` vs. naive on
   `path/2` — `tests/cases/eval-semi-scans` and its naive twin pin 287 tuple
   scans against 398 on an eight-node chain. `stat_iterations` goes the other
   way, 7 against 3, and that is not a regression: `join()` re-reads the inner
   literal's relation size for every outer row, so a naive pass picks up what
   the same pass has just derived and is not one step of the closure, while a
   delta round's designated literal scans a delta that is fixed for the round.
6. Safe stratified negation works; recursion through negation is rejected.
7. Variables, symbols, strings, integers, and all six comparisons supported.
8. Embedded and `-q` queries both work; ground queries print `true`/`false`.
9. Naive and semi-naive agree on every test case and every generated program.
10. 700–1,200 lines of readable AWK, no code golf (spec §87).
11. `awklog -h` and `awklog file.dl` are enough for a new user.
