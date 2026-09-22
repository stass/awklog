# awklog -- convenience targets only; nothing here is needed to run awklog.

PREFIX?=	/usr/local
BINDIR?=	$(PREFIX)/bin
LIBEXECDIR?=	$(PREFIX)/libexec
INSTALL?=	install

all:
	@echo "nothing to build; try: make test, make install, make lint, make count"

test:
	sh tests/run.sh

install:
	$(INSTALL) -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBEXECDIR)
	$(INSTALL) -m 755 awklog $(DESTDIR)$(BINDIR)/awklog
	$(INSTALL) -m 644 awklog.awk $(DESTDIR)$(LIBEXECDIR)/awklog.awk

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/awklog $(DESTDIR)$(LIBEXECDIR)/awklog.awk

# Portability gate: constructs forbidden by PLAN.md section 13.
lint:
	@sh -n awklog && echo "awklog: sh syntax ok"
	@sh -n tests/run.sh && echo "tests/run.sh: sh syntax ok"
	@awk -f awklog.awk /dev/null && echo "awklog.awk: parses"
	@awk '{ if ($$0 ~ /^[ \t]*#/) print ""; else print }' awklog.awk | \
	if grep -n -E 'asorti?\(|gensub\(|PROCINFO|@namespace|typeof\(|switch *\(|length\([A-Za-z_][A-Za-z_0-9]*\)|\\s'; then \
		echo "lint: forbidden construct above" >&2; exit 1; \
	else echo "awklog.awk: no forbidden constructs"; fi

count:
	@awk 'END { print NR " lines in awklog.awk (budget 700-1200)" }' awklog.awk

.PHONY: all test install uninstall lint count
