# awklog -- a tiny stratified Datalog interpreter in portable AWK.
#
# Milestone M2 (PLAN.md section 11): option decoding, source collection,
# lexer, parser, diagnostics, the predicate and tuple tables and fact loading
# are in place.  Checking, stratification and evaluation are still stubs,
# filled in by M3-M6.
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

# --------------------------------------------------------------- stages ---
# Each stub is replaced by its milestone: M3 check_program and stratify,
# M4/M5 evaluate, M4 run_queries, M6 repl.

function check_program() { }

function stratify() { }

function evaluate() { }

function run_queries() { }

function repl() { }

# ------------------------------------------------------------ statistics ---

function print_stats(   p) {
	note("read " stat_lines " line(s) from " stat_files " file(s)")
	note(pred_n " predicate(s), " stat_input_facts " input fact(s), " \
		stat_rules " rule(s), " query_n " query(s)")
	if (stat_dup_facts > 0)
		note(stat_dup_facts " duplicate fact(s) collapsed")
	# Relation sizes are per predicate and grow with the program, so they
	# are held back until -v -v.  Predicates come out in order of first
	# appearance, which is stable for a given source.
	if (opt_verbose >= 2)
		for (p = 1; p <= pred_n; p++)
			note(predicate_label(p) ": " pred_tuple_count[p] " tuple(s)")
}
