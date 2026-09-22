# awklog -- a tiny stratified Datalog interpreter in portable AWK.
#
# Milestone M0 (PLAN.md section 11): skeleton.  Option decoding, source
# collection, diagnostics and the END pipeline are in place; the stages
# themselves are stubs, filled in by M1-M6.
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

{
	source_add_line(FILENAME, FNR, $0)
}

END {
	if (dying)
		exit exit_code
	parse_all()
	check_program()
	stratify()
	evaluate()
	run_queries()
	repl()
	if (opt_verbose)
		print_stats()
	exit exit_code
}

# ---------------------------------------------------------------- options ---

function init() {
	# Keep number->string conversion exact everywhere: the default CONVFMT
	# of "%.6g" would turn 1000000 into 1e+06 inside tuple keys.
	CONVFMT = "%.17g"
	OFMT = "%.17g"
	SUBSEP = sprintf("%c", 28)

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

# All stages run in END, so exit here terminates immediately; the dying flag
# covers the one caller in BEGIN, where exit would otherwise fall into END.
function die(where, msg) {
	if (where != "")
		print where ": error: " msg > STDERR
	else
		print "awklog: error: " msg > STDERR
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
	if (fnr == 1)
		stat_files++
}

function source_where(i, col) {
	if (i < 1 || i > src_n)
		return "awklog"
	if (col > 0)
		return src_file[i] ":" src_fnr[i] ":" col
	return src_file[i] ":" src_fnr[i]
}

# --------------------------------------------------------------- stages ---
# Each stub is replaced by its milestone: M1 parse_all, M3 check_program and
# stratify, M4/M5 evaluate, M4 run_queries, M6 repl.

function parse_all() {
}

function check_program() {
}

function stratify() {
}

function evaluate() {
}

function run_queries() {
}

function repl() {
}

# ------------------------------------------------------------ statistics ---

function print_stats() {
	note("read " src_n " line(s) from " stat_files + 0 " file(s)")
}
