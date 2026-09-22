# awklog -- a tiny stratified Datalog interpreter in portable AWK.
#
# Milestone M4 (PLAN.md section 11): option decoding, source collection,
# lexer, parser, diagnostics, the predicate and tuple tables, fact loading,
# the safety checks, the dependency graph, stratification, the naive
# evaluator, queries and text output are in place.  The semi-naive engine
# (M5), the csv and tsv formats, -s, -n and the REPL (M6) are still to come;
# -D semi currently runs the naive evaluator.
#
# Portability (PLAN.md section 13): POSIX awk only.  No gensub, asort/asorti,
# PROCINFO, arrays of arrays, switch, typeof, indirect calls, length(array),
# delete of a whole array, or regex shorthands such as \s.  Two-dimensional
# access is always a[x, y] with an explicit SUBSEP.
#
# Settings arrive in the environment as AWKLOG_* (set by the awklog wrapper);
# an explicit -v awklog_* assignment wins, so direct
#
#	awk -v awklog_query='edge(X, Y)?' -f awklog.awk graph.dl
#
# stays ergonomic.

BEGIN {
	init()
}

FNR == 1 {
	stat_files++
}

{
	source_add_line(FILENAME, FNR, $0)
}

END {
	if (dying)
		exit exit_code
	parse_all()
	load_facts()
	check_program()
	stratify()
	if (!opt_check) {
		evaluate()
		run_queries()
		repl()
	}
	if (opt_verbose)
		print_stats()
	exit exit_code
}

# ---------------------------------------------------------------- options ---

function init() {
	# Belt and braces only: POSIX converts an integral value with %d and
	# consults CONVFMT just for the rest, and v1 has no non-integral values
	# to reach it.  Measured under CONVFMT="%.6g", all four awks render
	# 1000000 and 100000000000000000 as digits (PLAN.md section 4).
	CONVFMT = "%.17g"
	OFMT = "%.17g"
	SUBSEP = sprintf("%c", 28)

	# The lexer classifies bytes with index() into these sets rather than
	# scanning tokens with match(), which takes no start offset and so would
	# copy the rest of the line for every token (PLAN.md §14.8).
	UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	LOWER = "abcdefghijklmnopqrstuvwxyz"
	DIGITS = "0123456789"
	WORDCH = UPPER LOWER DIGITS "_"

	STDERR = opt_str(awklog_stderr, "AWKLOG_STDERR", "/dev/stderr")
	STDIN = opt_str(awklog_stdin, "AWKLOG_STDIN", "/dev/stdin")
	PROMPT = opt_str(awklog_prompt, "AWKLOG_PROMPT", "")

	opt_query = opt_str(awklog_query, "AWKLOG_QUERY", "")
	opt_format = opt_str(awklog_format, "AWKLOG_FORMAT", "text")
	opt_mode = opt_str(awklog_mode, "AWKLOG_MODE", "semi")
	opt_check = opt_num(awklog_check, "AWKLOG_CHECK", 0)
	opt_quiet = opt_num(awklog_quiet, "AWKLOG_QUIET", 0)
	opt_sort = opt_num(awklog_sort, "AWKLOG_SORT", 0)
	opt_interactive = opt_num(awklog_interactive, "AWKLOG_INTERACTIVE", 0)
	opt_verbose = opt_num(awklog_verbose, "AWKLOG_VERBOSE", 0)

	if (opt_format != "text" && opt_format != "csv" && opt_format != "tsv")
		usage_error("unknown output format: " opt_format)
	if (opt_mode != "semi" && opt_mode != "naive")
		usage_error("unknown evaluation mode: " opt_mode)

	# csv, tsv, -s, -n and -i arrive with M6 (PLAN.md section 11).  Until
	# they do they are refused rather than accepted and ignored: with M4's
	# query output in place, accepting them would print text for -F csv,
	# unsorted rows for -s, and rows at all for -n.  The wrapper refuses
	# them first; this is the direct-invocation path.
	if (opt_format != "text")
		usage_error("output format " opt_format " is not implemented yet")
	if (opt_sort)
		usage_error("-s is not implemented yet")
	if (opt_quiet)
		usage_error("-n is not implemented yet")
	if (opt_interactive)
		usage_error("-i is not implemented yet")

	src_n = 0
	stat_lines = 0
	pred_n = 0
	tuple_n = 0
	rule_n = 0
	query_n = 0
	stat_files = 0
	stat_input_facts = 0
	stat_dup_facts = 0
	stat_rules = 0
	stat_undefined = 0
	stat_derived_facts = 0
	stat_rule_runs = 0
	stat_tuple_scans = 0
	stat_iterations = 0
	max_stratum = 0
	join_stop = 0
	exit_code = 0
	dying = 0
}

# An unset awk variable is "", so a -v assignment takes precedence over the
# environment only when it actually carries a value.
function opt_str(v, name, dflt) {
	if (v != "")
		return v
	if (name in ENVIRON && ENVIRON[name] != "")
		return ENVIRON[name]
	return dflt
}

function opt_num(v, name, dflt) {
	return opt_str(v, name, dflt) + 0
}

# ------------------------------------------------------------ diagnostics ---

# Messages carry their own classification ("syntax error: ...", "unsafe rule:
# ...") so that a located diagnostic reads exactly as spec §64 shows it:
#
#	project.dl:14:3: syntax error: expected predicate
#
# All stages run in END, so exit here terminates immediately; the dying flag
# covers the one caller in BEGIN, where exit would otherwise fall into END.
function die(where, msg) {
	if (where != "")
		print where ": " msg > STDERR
	else
		print "awklog: " msg > STDERR
	close(STDERR)
	exit_code = 1
	dying = 1
	exit 1
}

function usage_error(msg) {
	print "awklog: " msg > STDERR
	close(STDERR)
	exit_code = 2
	dying = 1
	exit 2
}

function warn(where, msg) {
	if (where != "")
		print where ": warning: " msg > STDERR
	else
		print "awklog: warning: " msg > STDERR
}

function note(msg) {
	print "awklog: " msg > STDERR
}

# How a token is named in a diagnostic.
function token_desc(kind, text) {
	if (kind == "EOF")
		return "end of input"
	if (kind == "IDENT" || kind == "VAR" || kind == "INT")
		return "'" text "'"
	if (kind == "STR")
		return "a string literal"
	if (kind == "ANON")
		return "'_'"
	return "'" kind "'"
}

# Whole-array delete is not POSIX, so every array is emptied through here.
function array_clear(a, k) {
	for (k in a)
		delete a[k]
}

# --------------------------------------------------------------- sources ---

# Input lines are kept with their origin so that the lexer's (line, column)
# cursor yields file:line:col diagnostics with no offset mapping table.
function source_add_line(file, fnr, text) {
	if (file == "")
		file = "<stdin>"
	src_n++
	src_file[src_n] = file
	src_fnr[src_n] = fnr
	src_text[src_n] = text
}

function source_where(i, col) {
	if (i < 1 || i > src_n)
		return "awklog"
	if (col > 0)
		return src_file[i] ":" src_fnr[i] ":" col
	return src_file[i] ":" src_fnr[i]
}

# Query text from -q becomes ordinary source lines, so it lexes with the same
# cursor and reports the same file:line:col diagnostics (PLAN.md section 10).
function source_add_query(text,   parts, i, n, start) {
	start = src_n + 1
	n = split(text, parts, "\n")
	for (i = 1; i <= n; i++)
		source_add_line("<query>", i, parts[i])
	return start
}

# ----------------------------------------------------------------- lexer ---
#
# The cursor is (lex_i, lex_col): an index into src_text[] and a 1-based
# column.  Keeping the lines separate instead of concatenating them into one
# buffer (spec §19, PLAN.md section 5) gives every token a file:line:col
# for free; statements still span lines because the scanner walks through line
# ends transparently.
#
# Token kinds are IDENT, VAR, ANON, INT, STR, not, EOF and the punctuation
# spelled as itself ("(", ")", ",", ".", "?", ":-", "=", "!=", "<", "<=", ">",
# ">="), so a diagnostic can name a token without a translation table.

function lex_start(i) {
	lex_i = i
	lex_col = 1
	lex_end_ln = 0
	lex_end_col = 0
	have_peek = 0
	tok_kind = ""
	tok_text = ""
	tok_ln = i
	tok_col = 1
}

# The scanner always fills the lookahead slot pk_*, and lex_next() moves that
# slot into tok_*; one token of pushback is enough for the whole grammar
# (spec §17), and keeping the two slots apart saves saving and restoring the
# current token around every peek.
function lex_next() {
	if (!have_peek)
		lex_scan()
	have_peek = 0
	tok_kind = pk_kind
	tok_text = pk_text
	tok_ln = pk_ln
	tok_col = pk_col
	return tok_kind
}

function lex_peek() {
	if (!have_peek) {
		lex_scan()
		have_peek = 1
	}
	return pk_kind
}

# Whitespace and %-comments are skipped between tokens, so a % inside a string
# literal is safe by construction (spec §16).
function lex_skip_space(   c) {
	while (lex_i <= src_n) {
		# substr() past the end of a line returns "", which is how the
		# scanner detects end of line; length() on a bare name is what
		# the portability lint forbids.
		c = substr(src_text[lex_i], lex_col, 1)
		if (c == "" || c == "%") {
			# Remember where the source ran out, so that the EOF token
			# still carries a location for "unexpected end of input".
			# A comment runs to the end of the line, so step over it
			# first: pointing the caret inside it would be misleading.
			if (c == "%")
				lex_col = lex_line_end(src_text[lex_i], lex_col)
			lex_end_ln = lex_i
			lex_end_col = lex_col
			lex_i++
			lex_col = 1
		} else if (c == " " || c == "\t" || c == "\r") {
			lex_col++
		} else {
			return
		}
	}
}

function lex_scan(   line, c, n, span) {
	lex_skip_space()
	pk_ln = lex_i
	pk_col = lex_col
	pk_text = ""
	if (lex_i > src_n) {
		pk_ln = lex_end_ln
		pk_col = lex_end_col
		return pk_kind = "EOF"
	}
	line = src_text[lex_i]
	c = substr(line, lex_col, 1)

	if (c == "\"")
		return lex_string(line)

	if (index(WORDCH, c) > 0 && index(DIGITS, c) == 0) {
		span = lex_span(line, lex_col, WORDCH)
		pk_text = substr(line, lex_col, span)
		lex_col += span
		return pk_kind = lex_word_kind(pk_text)
	}

	# "-" is a sign on a numeric literal, never an operator: v1 has no
	# arithmetic (spec §7.3, PLAN.md section 5).
	if (c == "-" || index(DIGITS, c) > 0) {
		n = (c == "-") ? 1 : 0
		span = lex_span(line, lex_col + n, DIGITS)
		if (span == 0)
			lex_error(lex_i, lex_col, "expected a digit after '-'")
		pk_text = substr(line, lex_col, n + span)
		lex_col += n + span
		return pk_kind = "INT"
	}

	if (c == "(" || c == ")" || c == "," || c == "." || c == "?") {
		lex_col++
		return pk_kind = c
	}
	if (c == ":") {
		if (substr(line, lex_col + 1, 1) != "-")
			lex_error(lex_i, lex_col, "expected ':-'")
		lex_col += 2
		return pk_kind = ":-"
	}
	if (c == "!") {
		if (substr(line, lex_col + 1, 1) != "=")
			lex_error(lex_i, lex_col, "expected '!='")
		lex_col += 2
		return pk_kind = "!="
	}
	if (c == "<" || c == ">") {
		lex_col++
		if (substr(line, lex_col, 1) == "=") {
			lex_col++
			return pk_kind = c "="
		}
		return pk_kind = c
	}
	if (c == "=") {
		lex_col++
		return pk_kind = "="
	}
	lex_error(lex_i, lex_col, "unexpected character '" c "'")
}

# The column one past the last byte of line.
function lex_line_end(line, col) {
	while (substr(line, col, 1) != "")
		col++
	return col
}

# Number of consecutive bytes of set starting at col.
function lex_span(line, col, set,   n, c) {
	n = 0
	for (;;) {
		c = substr(line, col + n, 1)
		if (c == "" || index(set, c) == 0)
			break
		n++
	}
	return n
}

function lex_word_kind(w,   c) {
	if (w == "not")
		return "not"
	if (w == "_")
		return "ANON"
	c = substr(w, 1, 1)
	if (index(UPPER, c) > 0)
		return "VAR"
	if (index(LOWER, c) > 0)
		return "IDENT"
	lex_error(pk_ln, pk_col, "'" w "' is not a valid name: predicates and " \
		"symbols begin with a lowercase letter, variables with an uppercase one")
}

# String literals do not span lines; escapes are exactly those of spec §7.2.
function lex_string(line,   col, start, c, esc, out) {
	start = lex_col
	col = lex_col + 1
	out = ""
	for (;;) {
		c = substr(line, col, 1)
		if (c == "")
			lex_error(lex_i, start, "unterminated string literal")
		if (c == "\"") {
			col++
			break
		}
		if (c == "\\") {
			col++
			c = substr(line, col, 1)
			if (c == "")
				lex_error(lex_i, start, "unterminated string literal")
			# The two tables are parallel: \\ \" n t r -> \ " NL TAB CR.
			esc = index("\\\"ntr", c)
			if (esc == 0)
				# col is on the escaped character; point at the backslash.
				lex_error(lex_i, col - 1, "unknown escape '\\" c "' in string literal")
			out = out substr("\\\"\n\t\r", esc, 1)
			col++
			continue
		}
		out = out c
		col++
	}
	lex_col = col
	pk_text = out
	return pk_kind = "STR"
}

function lex_error(ln, col, msg) {
	die(source_where(ln, col), "syntax error: " msg)
}

# -------------------------------------------------------- symbols, values ---

function predicate_get(name, arity,   key) {
	key = name SUBSEP arity
	if (key in pred_id)
		return pred_id[key]
	pred_n++
	pred_id[key] = pred_n
	pred_name[pred_n] = name
	pred_arity[pred_n] = arity
	# Seeded because every relation scan reads it and reading an absent
	# element would create it (PLAN.md section 15).  pred_has_fact and
	# pred_has_rule are deliberately left absent instead: seeding them would
	# make (p in pred_has_rule) true for every predicate, and that test is
	# how the stratifier will ask whether a predicate has a definition.
	pred_tuple_count[pred_n] = 0
	return pred_n
}

function predicate_label(p) {
	return pred_name[p] "/" pred_arity[p]
}

# Constants carry a type tag (spec §26) so that foo, "foo" and 42 are
# three distinct values under equality and inside tuple keys.
function value_encode(kind, text) {
	if (kind == "n")
		return "n:" number_text(text + 0)
	return kind ":" value_escape(text)
}

# Tuple keys join encoded values with SUBSEP, so a SUBSEP (or the escape
# character itself) inside a string constant could otherwise forge another
# tuple's key; escaping here makes key construction injective.
function value_escape(s,   out, c, i) {
	if (index(s, "\\") == 0 && index(s, SUBSEP) == 0)
		return s
	out = ""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c == "\\")
			out = out "\\\\"
		else if (c == SUBSEP)
			out = out "\\S"
		else
			out = out c
	}
	return out
}

# The encoded spelling of a number is built explicitly rather than left to the
# host's number->string rule: below 2^53 %d is exact, and above it a host's %d
# may convert through an integer type too narrow to hold the value, so those go
# through %.17g, which round-trips a double (PLAN.md section 4, spec §7.3).
function number_text(v) {
	if (v == int(v) && v < 9007199254740992 && v > -9007199254740992)
		return sprintf("%d", v)
	return sprintf("%.17g", v)
}

# ----------------------------------------------------------- tuple store ---
#
# A tuple is one ground row of a relation (spec §24).  Rows are interned under
#
#	predicate-id SUBSEP encoded-arg-1 SUBSEP ... SUBSEP encoded-arg-n
#
# so re-deriving a row is one hash lookup and set semantics fall out of the
# array (spec §25).  That key is injective only because value_encode() escapes
# SUBSEP and the backslash inside constants: otherwise the two rows
#
#	p("x" SUBSEP "q:y", "z")	p("x", "y" SUBSEP "q:z")
#
# would spell the same key and the second would vanish as a duplicate.
#
# Arguments arrive in an array rather than one packed string because a caller
# usually has them in separate places already (head terms here, bindings in the
# evaluator), and packing them twice would cost a scan per candidate row.

function tuple_key(p, n, argv,   key, k) {
	key = p
	for (k = 1; k <= n; k++)
		key = key SUBSEP argv[k]
	return key
}

# Interns argv[1..n] as a row of predicate p and returns its tuple id.  Whether
# the row was new is reported through the global tuple_added, since an awk
# function returns one scalar.
function tuple_add(p, n, argv,   key, t, k) {
	key = tuple_key(p, n, argv)
	if (key in tuple_exists) {
		tuple_added = 0
		return tuple_exists[key]
	}
	tuple_n++
	t = tuple_n
	tuple_exists[key] = t
	tuple_pred[t] = p
	for (k = 1; k <= n; k++)
		tuple_arg[t, k] = argv[k]
	pred_tuple_count[p]++
	pred_tuple[p, pred_tuple_count[p]] = t
	tuple_added = 1
	return t
}

# ---------------------------------------------------------------- parser ---
#
# Recursive descent with one token of lookahead (spec §18).  Facts,
# rules and queries all become rules: a fact is a rule with an empty body, and
# a query is a rule whose synthetic head carries its named variables in order
# of first appearance (spec §14).  The head of a fact or rule is parsed
# as body literal 1 and moved by rule_promote_head(), because no amount of
# lookahead at the first literal tells "head :- body" from "literal, literal?".

function parse_all(   start) {
	# Query text is appended to the same array below, so the input-file
	# line count has to be taken before that.
	stat_lines = src_n
	lex_start(1)
	parse_program(0)
	if (opt_query != "") {
		start = source_add_query(opt_query)
		lex_start(start)
		parse_program(1)
	}
}

function parse_program(query_only) {
	while (lex_peek() != "EOF")
		parse_statement(query_only)
}

function parse_statement(query_only,   r, k, n) {
	lex_peek()
	r = rule_new(pk_ln, pk_col)
	parse_literal(r, 1)
	k = lex_peek()
	if (k == ":-") {
		lex_next()
		if (rule_lit_kind[r, 1] != 1)
			die(source_where(rule_line[r], rule_col[r]),
				"syntax error: a rule head must be a positive atom")
		rule_promote_head(r)
		n = 0
		for (;;) {
			n++
			parse_literal(r, n)
			if (lex_peek() != ",")
				break
			lex_next()
		}
		rule_body_n[r] = n
		expect(".", "'.'")
		pred_has_rule[rule_head_pred[r]] = 1
		stat_rules++
	} else if (k == ".") {
		lex_next()
		if (rule_lit_kind[r, 1] != 1)
			die(source_where(rule_line[r], rule_col[r]),
				"syntax error: a fact must be a positive atom")
		rule_promote_head(r)
		rule_body_n[r] = 0
		rule_is_fact[r] = 1
		pred_has_fact[rule_head_pred[r]] = 1
	} else if (k == "," || k == "?") {
		n = 1
		while (lex_peek() == ",") {
			lex_next()
			n++
			parse_literal(r, n)
		}
		rule_body_n[r] = n
		expect("?", "'?'")
		rule_is_query[r] = 1
		rule_query_head(r)
		query_n++
		query_rule[query_n] = r
	} else {
		die(source_where(pk_ln, pk_col), "syntax error: expected ':-', '.' " \
			"or '?', found " token_desc(pk_kind, pk_text))
	}
	if (query_only && !rule_is_query[r])
		die(source_where(rule_line[r], rule_col[r]),
			"error: only queries may be given with -q")
}

function rule_new(ln, col,   r) {
	rule_n++
	r = rule_n
	rule_line[r] = ln
	rule_col[r] = col
	rule_head_pred[r] = 0
	rule_head_arity[r] = 0
	rule_body_n[r] = 0
	rule_var_n[r] = 0
	rule_is_fact[r] = 0
	rule_is_query[r] = 0
	return r
}

function rule_promote_head(r,   k, n) {
	rule_head_pred[r] = rule_lit_pred[r, 1]
	n = rule_lit_arity[r, 1]
	rule_head_arity[r] = n
	for (k = 1; k <= n; k++) {
		rule_head_kind[r, k] = term_kind[r, 1, k]
		rule_head_val[r, k] = term_val[r, 1, k]
	}
}

# A query's columns are its named variables in order of first appearance
# (spec §14); anonymous variables are never projected.  The head
# predicate stays 0: a query emits rows, it does not populate a relation.
function rule_query_head(r,   s, n) {
	n = 0
	for (s = 1; s <= rule_var_n[r]; s++) {
		if (rule_var_name[r, s] == "")
			continue
		n++
		rule_head_kind[r, n] = 1
		rule_head_val[r, n] = s
	}
	rule_head_arity[r] = n
}

# literal := atom | "not" atom | comparison
#
# An IDENT in literal position starts an atom unless a comparison operator
# follows it, in which case it is a bare symbol operand ("foo = X").
function parse_literal(r, i,   k, name, ln, col) {
	k = lex_peek()
	if (k == "not") {
		lex_next()
		expect("IDENT", "a predicate name")
		rule_lit_kind[r, i] = 2
		parse_atom(r, i, tok_text, tok_ln, tok_col)
		return
	}
	if (k == "IDENT") {
		lex_next()
		name = tok_text
		ln = tok_ln
		col = tok_col
		if (!comparator_p(lex_peek())) {
			rule_lit_kind[r, i] = 1
			parse_atom(r, i, name, ln, col)
			return
		}
		pt_kind = 2
		pt_val = value_encode("s", name)
		parse_comparison(r, i, ln, col)
		return
	}
	if (k == "VAR" || k == "ANON" || k == "INT" || k == "STR") {
		ln = pk_ln
		col = pk_col
		parse_term(r)
		parse_comparison(r, i, ln, col)
		return
	}
	die(source_where(pk_ln, pk_col),
		"syntax error: expected a literal, found " token_desc(pk_kind, pk_text))
}

# atom := IDENT [ "(" [term ("," term)*] ")" ]   -- the name is already read.
function parse_atom(r, i, name, ln, col,   argc) {
	argc = 0
	if (lex_peek() == "(") {
		lex_next()
		if (lex_peek() == ")") {
			lex_next()
		} else {
			for (;;) {
				argc++
				parse_term(r)
				term_kind[r, i, argc] = pt_kind
				term_val[r, i, argc] = pt_val
				if (lex_peek() != ",")
					break
				lex_next()
			}
			expect(")", "')'")
		}
	}
	rule_lit_pred[r, i] = predicate_get(name, argc)
	rule_lit_arity[r, i] = argc
	rule_lit_line[r, i] = ln
	rule_lit_col[r, i] = col
}

# comparison := term comparator term   -- the left operand is in pt_kind/pt_val.
function parse_comparison(r, i, ln, col,   op) {
	term_kind[r, i, 1] = pt_kind
	term_val[r, i, 1] = pt_val
	op = lex_next()
	if (!comparator_p(op))
		die(source_where(tok_ln, tok_col), "syntax error: expected a " \
			"comparison operator, found " token_desc(tok_kind, tok_text))
	parse_term(r)
	term_kind[r, i, 2] = pt_kind
	term_val[r, i, 2] = pt_val
	rule_lit_kind[r, i] = 3
	rule_lit_pred[r, i] = 0
	rule_lit_op[r, i] = op
	rule_lit_arity[r, i] = 2
	rule_lit_line[r, i] = ln
	rule_lit_col[r, i] = col
	# Where the right operand starts, so that a type error on it points at
	# the operand and not at the head of the whole comparison.  parse_term()
	# consumed exactly one token, so tok_* still names it.
	rule_lit_rhs_ln[r, i] = tok_ln
	rule_lit_rhs_col[r, i] = tok_col
}

# Terms return through pt_kind/pt_val: 1 variable slot, 2 symbol, 3 string,
# 4 number, with constants already encoded (spec §26).
function parse_term(r,   k) {
	k = lex_next()
	if (k == "VAR") {
		pt_kind = 1
		pt_val = var_slot(r, tok_text)
	} else if (k == "ANON") {
		pt_kind = 1
		pt_val = var_slot(r, "")
	} else if (k == "IDENT") {
		pt_kind = 2
		pt_val = value_encode("s", tok_text)
	} else if (k == "STR") {
		pt_kind = 3
		pt_val = value_encode("q", tok_text)
	} else if (k == "INT") {
		pt_kind = 4
		pt_val = value_encode("n", tok_text)
	} else {
		die(source_where(tok_ln, tok_col),
			"syntax error: expected a term, found " token_desc(tok_kind, tok_text))
	}
}

# Slots are numbered in order of first appearance (spec §22).  Every
# occurrence of _ gets a fresh nameless slot, so pair(_, _) does not force the
# two arguments to be equal (spec §9).
function var_slot(r, name,   s) {
	if (name != "" && (r, name) in rule_var_slot)
		return rule_var_slot[r, name]
	rule_var_n[r]++
	s = rule_var_n[r]
	rule_var_name[r, s] = name
	if (name != "")
		rule_var_slot[r, name] = s
	return s
}

function comparator_p(k) {
	return k == "=" || k == "!=" || k == "<" || k == "<=" || k == ">" || k == ">="
}

function expect(kind, what) {
	if (lex_next() != kind)
		die(source_where(tok_ln, tok_col), "syntax error: expected " what \
			", found " token_desc(tok_kind, tok_text))
}

# ---------------------------------------------------------- fact loading ---

# A fact is a rule with an empty body and must be ground (spec §5.1), so it is
# stored directly instead of being evaluated.  Loading runs before the semantic
# checks so that -c reports the relation sizes it would really evaluate over,
# and so that a missing-variable diagnostic names the fact that carries it.
function load_facts(   r, p, n, k, name, argv) {
	for (r = 1; r <= rule_n; r++) {
		if (!rule_is_fact[r])
			continue
		p = rule_head_pred[r]
		n = rule_head_arity[r]
		for (k = 1; k <= n; k++) {
			if (rule_head_kind[r, k] == 1) {
				name = rule_var_name[r, rule_head_val[r, k]]
				if (name == "")
					name = "_"
				die(source_where(rule_line[r], rule_col[r]),
					"error: a fact must be ground: " \
					predicate_label(p) " contains variable '" name "'")
			}
			argv[k] = rule_head_val[r, k]
		}
		# Stale argv entries past n are never read: the key stops at n.
		tuple_add(p, n, argv)
		if (tuple_added)
			stat_input_facts++
		else
			stat_dup_facts++
	}
}

# ---------------------------------------------------------------- checks ---
#
# Safety is decided statically and independently of the order the body is
# written in, because the evaluator reorders literals (spec §33, §35): the set
# of slots a positive body literal can bind is collected over the whole body
# first, and every other literal is then measured against it.

function check_program(   r) {
	for (r = 1; r <= rule_n; r++)
		if (!rule_is_fact[r])
			check_rule_safety(r)
	check_undefined()
}

function check_rule_safety(r,   bound, i, k, kind) {
	# posbound(r): every slot bound by a positive body literal (spec §32).
	for (i = 1; i <= rule_body_n[r]; i++) {
		if (rule_lit_kind[r, i] != 1)
			continue
		for (k = 1; k <= rule_lit_arity[r, i]; k++)
			if (term_kind[r, i, k] == 1)
				bound[term_val[r, i, k]] = 1
	}
	for (i = 1; i <= rule_body_n[r]; i++) {
		kind = rule_lit_kind[r, i]
		# Negation is membership on a ground tuple, so every argument
		# must already be bound (spec §33, §50); = is a filter and not a
		# binder in v1, so it needs no special case (spec §51).
		if (kind == 2)
			check_bound_terms(r, i, bound,
				"'not " predicate_label(rule_lit_pred[r, i]) "'")
		else if (kind == 3) {
			check_bound_terms(r, i, bound,
				"comparison '" rule_lit_op[r, i] "'")
			check_compare_types(r, i)
		}
	}
	check_head_safety(r, bound)
}

function check_bound_terms(r, i, bound, what,   k, s) {
	for (k = 1; k <= rule_lit_arity[r, i]; k++) {
		if (term_kind[r, i, k] != 1)
			continue
		s = term_val[r, i, k]
		if (s in bound)
			continue
		die(source_where(rule_lit_line[r, i], rule_lit_col[r, i]),
			"error: unsafe " rule_noun(r) ": variable '" var_display(r, s) \
			"' in " what " is not bound by a positive body literal")
	}
}

# Range restriction (spec §32).  A query's synthetic head carries its named
# variables, which is the same rule seen from spec §14.
function check_head_safety(r, bound,   k, s, where) {
	where = source_where(rule_line[r], rule_col[r])
	for (k = 1; k <= rule_head_arity[r]; k++) {
		if (rule_head_kind[r, k] != 1)
			continue
		s = rule_head_val[r, k]
		if (s in bound)
			continue
		if (rule_is_query[r])
			die(where, "error: unsafe query: variable '" var_display(r, s) \
				"' is not bound by a positive body literal")
		die(where, "error: unsafe rule: variable '" var_display(r, s) \
			"' in the head of " predicate_label(rule_head_pred[r]) \
			" is not bound by a positive body literal")
	}
}

# An ordering comparison is legal only where both operands resolve to numeric
# (spec §13).  A symbol or string constant never will, so it is rejected here
# rather than at run time, where the same operand would abort a query midway.
function check_compare_types(r, i,   op, k, kind, where) {
	op = rule_lit_op[r, i]
	if (op == "=" || op == "!=")
		return
	for (k = 1; k <= 2; k++) {
		kind = term_kind[r, i, k]
		if (kind != 2 && kind != 3)
			continue
		# The literal's own location is its left operand; the right one
		# was recorded separately so the caret lands on the offender.
		if (k == 1)
			where = source_where(rule_lit_line[r, i], rule_lit_col[r, i])
		else
			where = source_where(rule_lit_rhs_ln[r, i], rule_lit_rhs_col[r, i])
		die(where, "error: ordering comparison '" op "' requires " \
			"numeric operands, found " \
			(kind == 2 ? "a symbol" : "a string literal"))
	}
}

# A predicate with neither facts nor rules is an empty relation rather than an
# error, so that a program whose fact file is absent still runs; the warning
# goes to stderr, leaving stdout clean for pipelines (PLAN.md section 6).
function check_undefined(   r, i, p) {
	for (r = 1; r <= rule_n; r++)
		for (i = 1; i <= rule_body_n[r]; i++) {
			if (rule_lit_kind[r, i] == 3)
				continue
			p = rule_lit_pred[r, i]
			if ((p in pred_has_fact) || (p in pred_has_rule))
				continue
			if (p in pred_undefined)
				continue
			pred_undefined[p] = 1
			stat_undefined++
			warn(source_where(rule_lit_line[r, i], rule_lit_col[r, i]),
				"undefined predicate " predicate_label(p) \
				": no facts and no rules, treated as empty")
		}
}

function rule_noun(r) {
	return rule_is_query[r] ? "query" : "rule"
}

function var_display(r, s) {
	return rule_var_name[r, s] == "" ? "_" : rule_var_name[r, s]
}

# ------------------------------------------------- dependencies and strata ---

# One edge per head/body-literal pair (spec §36).  Facts have no body and a
# query has no head, so neither contributes.
function build_deps(   r, i, p, q, kind) {
	for (r = 1; r <= rule_n; r++) {
		if (rule_is_fact[r] || rule_is_query[r])
			continue
		p = rule_head_pred[r]
		for (i = 1; i <= rule_body_n[r]; i++) {
			kind = rule_lit_kind[r, i]
			if (kind == 3)
				continue
			q = rule_lit_pred[r, i]
			if (kind == 1)
				dep_pos[p, q] = 1
			else
				dep_neg[p, q] = 1
		}
	}
}

# The spec's relaxation (§37): raise stratum[p] until every positive edge
# satisfies stratum[p] >= stratum[q] and every negative one stratum[p] >
# stratum[q].  O(P^3) worst case, which is what §36 asks for, and it needs no
# SCC machinery.
function stratify(   p, q, s, changed) {
	build_deps()
	for (p = 1; p <= pred_n; p++)
		stratum[p] = 0
	max_stratum = 0
	changed = 1
	while (changed) {
		changed = 0
		for (p = 1; p <= pred_n; p++)
			for (q = 1; q <= pred_n; q++) {
				s = stratum[p]
				if ((p, q) in dep_pos && s < stratum[q])
					s = stratum[q]
				if ((p, q) in dep_neg && s <= stratum[q])
					s = stratum[q] + 1
				if (s == stratum[p])
					continue
				# No valid stratification of P predicates
				# needs a stratum above P-1, so passing that
				# bound proves a cycle through negation
				# (spec §38).
				if (s >= pred_n)
					stratify_fail(p)
				stratum[p] = s
				changed = 1
			}
	}
	for (p = 1; p <= pred_n; p++)
		if (stratum[p] > max_stratum)
			max_stratum = stratum[p]
	build_recursive()
}

# The predicate whose stratum crossed the bound is as often above the cycle as
# on it -- every predicate depending on a climbing one climbs with it -- so it
# would point the diagnostic at an innocent rule.  Name instead a predicate
# that a negative edge really leads back into: p -> q negatively with q
# leading back to p by any edges is a cycle through negation by definition.
function stratify_fail(p,   c) {
	c = negative_cycle_pred()
	if (c > 0)
		p = c
	die(pred_where(p), "error: program contains recursion through negation: " \
		predicate_label(p))
}

function negative_cycle_pred(   p, q, path) {
	for (p = 1; p <= pred_n; p++)
		for (q = 1; q <= pred_n; q++)
			if (((p, q) in dep_pos) || ((p, q) in dep_neg))
				path[p, q] = 1
	closure(path)
	for (p = 1; p <= pred_n; p++)
		for (q = 1; q <= pred_n; q++)
			if (((p, q) in dep_neg) && (p == q || ((q, p) in path)))
				return p
	return 0
}

# spec §48: a predicate that positively reaches itself within its own stratum
# is what drives a fixpoint, so the rest can skip the delta loop (M5).  A
# positive cycle lies wholly inside one stratum, so seeding with same-stratum
# edges alone loses nothing.
function build_recursive(   p, q) {
	for (p = 1; p <= pred_n; p++)
		for (q = 1; q <= pred_n; q++)
			if (((p, q) in dep_pos) && stratum[p] == stratum[q])
				reach[p, q] = 1
	closure(reach)
	for (p = 1; p <= pred_n; p++)
		if ((p, p) in reach)
			pred_recursive[p] = 1
}

# Transitive closure in place, over a P x P edge set.  O(P^3) is what spec §36
# asks for at this scale, and it needs no SCC machinery; the array comes in as
# a parameter so that both the recursive-component test and the negative-cycle
# diagnostic can use it.
function closure(edge,   k, p, q) {
	for (k = 1; k <= pred_n; k++)
		for (p = 1; p <= pred_n; p++) {
			if (!((p, k) in edge))
				continue
			for (q = 1; q <= pred_n; q++)
				if ((k, q) in edge)
					edge[p, q] = 1
		}
}

# Where a predicate is defined, so that a stratification error can point into
# the source instead of naming the file alone (spec §38 shows either).
function pred_where(p,   r) {
	for (r = 1; r <= rule_n; r++)
		if (!rule_is_query[r] && rule_head_pred[r] == p)
			return source_where(rule_line[r], rule_col[r])
	return ""
}

# ------------------------------------------------------------ evaluation ---
#
# One stratum at a time, lowest first (spec §39).  A stratum's rules are
# re-run until a pass derives nothing new, which is the naive evaluator of
# spec §40; it stays as the correctness oracle behind -D naive, and M5 adds
# the semi-naive delta loop on top of the same eval_rule/join/match_tuple so
# the two engines cannot drift apart.

function evaluate(   s) {
	for (s = 0; s <= max_stratum; s++)
		eval_stratum(s)
}

# Rules are selected by the stratum of their head, and that is what freezes
# the lower strata while this one runs (spec §39): no rule evaluated here can
# insert into a relation belonging anywhere else, so a negated predicate is
# already complete by the time the stratum negating it is reached.
function eval_stratum(s,   r) {
	do {
		eval_added = 0
		stat_iterations++
		for (r = 1; r <= rule_n; r++) {
			if (rule_is_fact[r] || rule_is_query[r])
				continue
			if (stratum[rule_head_pred[r]] != s)
				continue
			eval_rule(r)
		}
	} while (eval_added)
}

function eval_rule(r,   n) {
	stat_rule_runs++
	n = plan_rule(r)
	join(r, n, 1)
}

# Body order is chosen per rule invocation rather than once at parse time, so
# the relation sizes it weighs are current (spec §35).  Order is a
# correctness matter and not only a speed one: safety is decided over the
# whole body regardless of the order it is written in (spec §33), so a source
# may legally write "not penguin(X), bird(X)" and the negation has to end up
# after the literal that binds X.
function plan_rule(r,   n, np, i, best, best_bound, best_size, nb, size) {
	n = rule_body_n[r]
	array_clear(plan_done)
	array_clear(plan_bound)
	np = 0
	while (np < n) {
		# A comparison or negation whose variables are all bound binds
		# nothing further and can only cut the search, so it is worth
		# more than any remaining relation scan.
		best = 0
		for (i = 1; i <= n; i++)
			if (!(i in plan_done) && rule_lit_kind[r, i] != 1 &&
			    plan_ready(r, i)) {
				best = i
				break
			}
		# Otherwise the positive literal with the most arguments
		# already bound, then the smallest relation, then the earliest
		# in the source: a total and deterministic rule, so one
		# program and dataset always evaluate in the same order.
		if (best == 0) {
			best_bound = -1
			best_size = 0
			for (i = 1; i <= n; i++) {
				if ((i in plan_done) || rule_lit_kind[r, i] != 1)
					continue
				nb = plan_bound_count(r, i)
				size = pred_tuple_count[rule_lit_pred[r, i]]
				if (nb > best_bound ||
				    (nb == best_bound && size < best_size)) {
					best = i
					best_bound = nb
					best_size = size
				}
			}
		}
		# Unreachable while check_rule_safety() has run, since it
		# leaves every comparison and negation bound by some positive
		# literal.  The fallback keeps the plan total rather than
		# silently dropping a filter should that ever stop holding.
		if (best == 0)
			for (i = 1; i <= n; i++)
				if (!(i in plan_done)) {
					best = i
					break
				}
		np++
		plan[np] = best
		plan_done[best] = 1
		plan_mark(r, best)
	}
	return n
}

# Only a positive literal binds, so only a positive literal marks; a
# comparison or negation reached through the fallback above must not be
# allowed to claim it bound anything.
function plan_mark(r, i,   k) {
	if (rule_lit_kind[r, i] != 1)
		return
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1)
			plan_bound[term_val[r, i, k]] = 1
}

function plan_ready(r, i,   k) {
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1 && !(term_val[r, i, k] in plan_bound))
			return 0
	return 1
}

function plan_bound_count(r, i,   k, n) {
	n = 0
	for (k = 1; k <= rule_lit_arity[r, i]; k++)
		if (term_kind[r, i, k] == 1 && (term_val[r, i, k] in plan_bound))
			n++
	return n
}

# Recursive nested-loop join over one binding environment (PLAN.md §8.1):
# each level binds what its literal needs, recurses, then undoes exactly its
# own bindings.  Depth is the body length, so it stays in single digits.
function join(r, n, pos,   i, kind, p, c, k, t) {
	if (pos > n) {
		if (rule_is_query[r])
			query_emit(r)
		else
			emit_head(r)
		return
	}
	i = plan[pos]
	kind = rule_lit_kind[r, i]
	if (kind == 3) {
		if (eval_compare(r, i))
			join(r, n, pos + 1)
		return
	}
	if (kind == 2) {
		if (eval_negation(r, i))
			join(r, n, pos + 1)
		return
	}
	p = rule_lit_pred[r, i]
	# The relation size is read once, before the scan, because a recursive
	# rule inserts into the very relation it is scanning: rows added while
	# this scan runs are left to the next round, which is what bounds the
	# loop.  Rows added earlier in the same round, by another rule or by
	# an outer level of this one, are in and are scanned -- spec §40 says
	# "evaluate rule against all facts", not against a frozen snapshot, so
	# the iteration count depends on the order the rules are written in.
	c = pred_tuple_count[p]
	for (k = 1; k <= c; k++) {
		t = pred_tuple[p, k]
		stat_tuple_scans++
		if (match_tuple(r, i, t, pos))
			join(r, n, pos + 1)
		unbind(pos)
		if (join_stop)
			return
	}
}

# spec §30: an unbound argument takes the tuple's value, a bound one or a
# constant must equal it.  No general unification.  Which slots this level
# bound is recorded per depth so that unbind() can revert just those.
function match_tuple(r, i, t, pos,   k, s, v) {
	bound_n[pos] = 0
	for (k = 1; k <= rule_lit_arity[r, i]; k++) {
		v = tuple_arg[t, k]
		if (term_kind[r, i, k] != 1) {
			if (term_val[r, i, k] != v)
				return 0
			continue
		}
		s = term_val[r, i, k]
		if (s in bind_has) {
			if (bind_val[s] != v)
				return 0
			continue
		}
		bind_has[s] = 1
		bind_val[s] = v
		bound_n[pos]++
		bound_at[pos, bound_n[pos]] = s
	}
	return 1
}

# bind_val is left behind: bind_has is what every read tests first, so one
# delete per slot is enough.
function unbind(pos,   j) {
	for (j = 1; j <= bound_n[pos]; j++)
		delete bind_has[bound_at[pos, j]]
	bound_n[pos] = 0
}

# Every argument is bound -- spec §33 is checked statically -- so negation is
# one membership test on the candidate key and never scans a relation
# (spec §49).
function eval_negation(r, i,   k, n, argv) {
	n = rule_lit_arity[r, i]
	for (k = 1; k <= n; k++)
		argv[k] = lit_value(r, i, k)
	return !(tuple_key(rule_lit_pred[r, i], n, argv) in tuple_exists)
}

# = and != compare encoded values, so foo, "foo" and 42 are three distinct
# values (spec §26).  Ordering is numeric only (spec §13); a non-numeric
# operand here arrived through a variable, which the static check cannot see,
# so it is a located run-time error rather than a silent failure that would
# be indistinguishable from "no such fact" (PLAN.md §14.7).
function eval_compare(r, i,   op, a, b) {
	a = lit_value(r, i, 1)
	b = lit_value(r, i, 2)
	op = rule_lit_op[r, i]
	if (op == "=")
		return a == b
	if (op == "!=")
		return a != b
	if (substr(a, 1, 2) != "n:")
		compare_type_error(r, i, 1, a)
	if (substr(b, 1, 2) != "n:")
		compare_type_error(r, i, 2, b)
	a = substr(a, 3) + 0
	b = substr(b, 3) + 0
	if (op == "<")
		return a < b
	if (op == "<=")
		return a <= b
	if (op == ">")
		return a > b
	return a >= b
}

# The literal's own location is its left operand; the right one was recorded
# separately at parse time so the caret lands on the offender.
function compare_type_error(r, i, k, v,   where) {
	if (k == 1)
		where = source_where(rule_lit_line[r, i], rule_lit_col[r, i])
	else
		where = source_where(rule_lit_rhs_ln[r, i], rule_lit_rhs_col[r, i])
	die(where, "error: ordering comparison '" rule_lit_op[r, i] \
		"' requires numeric operands, found " \
		(substr(v, 1, 1) == "s" ? "the symbol " : "the string ") \
		format_value(v))
}

# A literal argument as the evaluator sees it: an encoded constant, or the
# encoded value currently bound to its slot.
function lit_value(r, i, k) {
	if (term_kind[r, i, k] == 1)
		return bind_val[term_val[r, i, k]]
	return term_val[r, i, k]
}

function head_value(r, k) {
	if (rule_head_kind[r, k] == 1)
		return bind_val[rule_head_val[r, k]]
	return rule_head_val[r, k]
}

# The head of a rule whose body succeeded.  Deduplication is the tuple
# store's (spec §25), so a re-derived row costs one hash lookup and does not
# count as progress.
function emit_head(r,   p, n, k, argv) {
	p = rule_head_pred[r]
	n = rule_head_arity[r]
	for (k = 1; k <= n; k++)
		argv[k] = head_value(r, k)
	tuple_add(p, n, argv)
	if (!tuple_added)
		return
	eval_added++
	stat_derived_facts++
}

# --------------------------------------------------------------- queries ---
#
# Queries run after the fixpoint, in source order with any -q queries last
# (spec §52-54): a query never restricts what was materialised, there are no
# magic sets.  A query joins exactly like a rule; only the leaf differs, in
# emitting a row instead of inserting a tuple.

function run_queries(   q) {
	for (q = 1; q <= query_n; q++) {
		# A blank line between blocks, so several results stay
		# distinguishable (PLAN.md section 9).
		if (q > 1)
			print ""
		query_run(query_rule[q])
	}
}

function query_run(r,   n) {
	array_clear(query_seen)
	# Belt and braces: join() unbinds at every level on the way out, the
	# ground short-circuit included, so this is already empty.  A query
	# must not inherit a binding from anything, and M6's REPL will reach
	# here from states this milestone cannot see.
	array_clear(bind_has)
	query_rows = 0
	query_ground = (rule_head_arity[r] == 0)
	join_stop = 0
	n = plan_rule(r)
	join(r, n, 1)
	# Cleared on the way out too: a ground query leaves the flag set, and
	# evaluation, which M6's REPL re-enters after a query, reads the same
	# flag inside join().
	join_stop = 0
	# No columns means a ground query -- including one whose only
	# variables are anonymous, since those are never projected -- and a
	# ground query answers true or false (spec §15).
	if (query_ground)
		print (query_rows > 0 ? "true" : "false")
}

# Columns are the named variables in order of first appearance (spec §14).
# Two bindings of the anonymous variables can project one row, so rows are
# deduplicated on their encoded values rather than on the printed text: a
# symbol and a string can print alike in text format and are still distinct.
function query_emit(r,   k, v, key, row) {
	query_rows++
	if (query_ground) {
		join_stop = 1
		return
	}
	key = ""
	row = ""
	for (k = 1; k <= rule_head_arity[r]; k++) {
		v = bind_val[rule_head_val[r, k]]
		key = key SUBSEP v
		row = (k == 1) ? format_value(v) : row " " format_value(v)
	}
	if (key in query_seen)
		return
	query_seen[key] = 1
	print row
}

# ---------------------------------------------------------------- output ---
#
# Text format (spec §60): symbols and numbers bare, a string bare unless it
# is empty or carries whitespace or a quote, in which case it is quoted with
# the escapes of spec §7.2.  csv and tsv arrive with M6.

function format_value(v,   kind, text) {
	kind = substr(v, 1, 1)
	text = value_decode(substr(v, 3))
	if (kind == "q" && text_needs_quote(text))
		return text_quote(text)
	return text
}

# The inverse of value_escape(): \\ is a backslash, \S the SUBSEP byte.
function value_decode(s,   out, i, c) {
	if (index(s, "\\") == 0)
		return s
	out = ""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c != "\\") {
			out = out c
			continue
		}
		i++
		c = substr(s, i, 1)
		out = out (c == "S" ? SUBSEP : c)
	}
	return out
}

function text_needs_quote(s) {
	return s == "" || index(s, " ") || index(s, "\t") || index(s, "\n") ||
		index(s, "\r") || index(s, "\"")
}

function text_quote(s,   out, i, c) {
	out = "\""
	for (i = 1; ; i++) {
		c = substr(s, i, 1)
		if (c == "")
			break
		if (c == "\\")
			out = out "\\\\"
		else if (c == "\"")
			out = out "\\\""
		else if (c == "\n")
			out = out "\\n"
		else if (c == "\t")
			out = out "\\t"
		else if (c == "\r")
			out = out "\\r"
		else
			out = out c
	}
	return out "\""
}

# ----------------------------------------------------------------- stages ---
# The last stub, replaced by its milestone: M6 repl.

function repl() { }

# ------------------------------------------------------------ statistics ---

function print_stats(   p) {
	note("read " stat_lines " line(s) from " stat_files " file(s)")
	note(pred_n " predicate(s), " stat_input_facts " input fact(s), " \
		stat_rules " rule(s), " query_n " query(s), " \
		(max_stratum + 1) " stratum(s)")
	if (stat_dup_facts > 0)
		note(stat_dup_facts " duplicate fact(s) collapsed")
	if (stat_undefined > 0)
		note(stat_undefined " undefined predicate(s) treated as empty")
	# Only -c skips evaluation, so these would otherwise print a row of
	# zeros that reads as a result rather than as "not run".
	if (!opt_check)
		note(stat_derived_facts " derived fact(s) in " stat_iterations \
			" iteration(s), " stat_rule_runs " rule run(s), " \
			stat_tuple_scans " tuple scan(s)")
	# Relation sizes and strata are per predicate and grow with the program,
	# so they are held back until -v -v.  Predicates come out in order of
	# first appearance, which is stable for a given source.  The tuple count
	# comes first because a relation's size is what a -v -v reader is
	# usually after; recursive is printed only when it holds.
	if (opt_verbose >= 2)
		for (p = 1; p <= pred_n; p++)
			note(predicate_label(p) ": " pred_tuple_count[p] \
				" tuple(s), stratum " stratum[p] \
				((p in pred_recursive) ? ", recursive" : ""))
}
