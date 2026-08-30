FPC ?= fpc
CC ?= cc

SRC := src
BIN := bin
BUILD := build
CLI_BUILD := $(BUILD)/cli
SHARED_BUILD := $(BUILD)/shared
EXAMPLE_BUILD := $(BUILD)/examples
FPCFLAGS ?= -Mobjfpc -Scghi -O2 -CX -XX -Xs -Fu$(SRC)
GCC_CRT_DIR ?= $(dir $(shell $(CC) -print-file-name=crtbegin.o 2>/dev/null))
FPC_CRTFLAGS ?= $(if $(wildcard $(GCC_CRT_DIR)crtbegin.o),-Fl$(GCC_CRT_DIR))

.PHONY: all cli shared examples test rtl-test c-api-test release-test check clean install uninstall dist distcheck

all: cli shared

$(BIN) $(CLI_BUILD) $(SHARED_BUILD) $(EXAMPLE_BUILD):
	mkdir -p $@

cli: $(BIN) $(CLI_BUILD)
	$(FPC) $(FPCFLAGS) $(FPC_CRTFLAGS) -FU$(CLI_BUILD) -FE$(BIN) -olfp $(SRC)/lfp.pas

shared: $(BIN) $(SHARED_BUILD)
	$(FPC) $(FPCFLAGS) $(FPC_CRTFLAGS) -Cg -FU$(SHARED_BUILD) -FE$(BIN) -oliblispal.so.1 $(SRC)/lfp_capi.pas
	ln -sfn liblispal.so.1 $(BIN)/liblispal.so

examples: cli shared $(EXAMPLE_BUILD)
	$(FPC) -Mobjfpc -O2 $(FPC_CRTFLAGS) -Fu$(SRC) -FE$(BIN) -FU$(EXAMPLE_BUILD) -oembed_pascal examples/embed_pascal.pas
	$(CC) -O2 -Iinclude examples/embed_c.c -L$(BIN) -llispal -Wl,-rpath,'$$ORIGIN' -o $(BIN)/embed_c

run-tour: cli
	./$(BIN)/lfp examples/pascal_tour.lfp

test: cli
	sh tests/run-tests.sh ./$(BIN)/lfp
	sh tests/run-repl-tests.sh ./$(BIN)/lfp

rtl-test: cli
	sh tests/run-rtl-tests.sh ./$(BIN)/lfp

c-api-test: shared
	$(CC) -std=c99 -Wall -Wextra -Werror -Iinclude tests/c_api.c -L$(BIN) -llispal -Wl,-rpath,'$$ORIGIN' -o $(BIN)/c_api_test
	./$(BIN)/c_api_test

release-test:
	sh tests/check-release.sh

check: release-test test rtl-test examples c-api-test
	./$(BIN)/embed_pascal
	./$(BIN)/embed_c

PREFIX ?= /usr/local
DOCDIR ?= $(PREFIX)/share/doc/lispal
PKGCONFIGDIR ?= $(PREFIX)/lib/pkgconfig
RTLDIR ?= $(PREFIX)/lib/lfp/rtl
ifeq ($(SKIP_BUILD),1)
install:
else
install: all
endif
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/lib $(DESTDIR)$(PREFIX)/include
	install -d $(DESTDIR)$(DOCDIR) $(DESTDIR)$(PKGCONFIGDIR) $(DESTDIR)$(RTLDIR)
	install -m 0755 $(BIN)/lfp $(DESTDIR)$(PREFIX)/bin/lfp
	install -m 0755 $(BIN)/liblispal.so.1 $(DESTDIR)$(PREFIX)/lib/liblispal.so.1
	ln -sfn liblispal.so.1 $(DESTDIR)$(PREFIX)/lib/liblispal.so
	install -m 0644 include/lispal.h $(DESTDIR)$(PREFIX)/include/lispal.h
	install -m 0644 lispal.pc $(DESTDIR)$(PKGCONFIGDIR)/lispal.pc
	install -m 0644 rtl/*.lpas $(DESTDIR)$(RTLDIR)/
	install -m 0644 README.md SECURITY.md LICENSE $(DESTDIR)$(DOCDIR)

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/lfp
	rm -f $(DESTDIR)$(PREFIX)/lib/liblispal.so
	rm -f $(DESTDIR)$(PREFIX)/lib/liblispal.so.1
	rm -f $(DESTDIR)$(PREFIX)/include/lispal.h
	rm -f $(DESTDIR)$(PKGCONFIGDIR)/lispal.pc
	rm -f $(DESTDIR)$(RTLDIR)/*.lpas
	rmdir $(DESTDIR)$(RTLDIR) 2>/dev/null || true
	rmdir $(DESTDIR)$(PREFIX)/lib/lfp 2>/dev/null || true
	rm -f $(DESTDIR)$(DOCDIR)/README.md
	rm -f $(DESTDIR)$(DOCDIR)/SECURITY.md
	rm -f $(DESTDIR)$(DOCDIR)/LICENSE
	rmdir $(DESTDIR)$(DOCDIR) 2>/dev/null || true

VERSION := $(shell cat VERSION)
DISTNAME := lfp-$(VERSION)
DISTCHECK_DIR := $(BUILD)/distcheck
DISTCHECK_SRC := $(DISTCHECK_DIR)/$(DISTNAME)
DISTCHECK_STAGE := $(DISTCHECK_DIR)/stage

dist: clean
	rm -rf $(BUILD)/$(DISTNAME) $(DISTNAME).tar.gz
	mkdir -p $(BUILD)/$(DISTNAME)
	cp -R src include examples tests rtl Makefile build.sh install.sh README.md SECURITY.md LICENSE VERSION lispal.pc .gitignore $(BUILD)/$(DISTNAME)/
	tar -C $(BUILD) -czf $(DISTNAME).tar.gz $(DISTNAME)
	@printf 'created %s\n' $(DISTNAME).tar.gz

distcheck: dist
	rm -rf $(DISTCHECK_DIR)
	mkdir -p $(DISTCHECK_DIR)
	tar -C $(DISTCHECK_DIR) -xzf $(DISTNAME).tar.gz
	$(MAKE) -C $(DISTCHECK_SRC) check
	$(MAKE) -C $(DISTCHECK_SRC) install SKIP_BUILD=1 PREFIX=/usr/local DESTDIR=../stage
	test -x $(DISTCHECK_STAGE)/usr/local/bin/lfp
	test -f $(DISTCHECK_STAGE)/usr/local/include/lispal.h
	test -L $(DISTCHECK_STAGE)/usr/local/lib/liblispal.so
	LFP_PATH=$(DISTCHECK_STAGE)/usr/local/lib/lfp/rtl $(DISTCHECK_STAGE)/usr/local/bin/lfp --no-jit -e '(uses Types UnixType) (var (u UnixType.TSize 7) (g Types.TSize (Types.TSize 3 4))) (+ u (field g cx) (field g cy))' | grep -Fx 14
	$(CC) -std=c99 -Wall -Wextra -Werror -I$(DISTCHECK_STAGE)/usr/local/include $(DISTCHECK_SRC)/tests/c_api.c -L$(DISTCHECK_STAGE)/usr/local/lib -llispal -o $(DISTCHECK_DIR)/staged_c_api_test
	LD_LIBRARY_PATH=$(DISTCHECK_STAGE)/usr/local/lib $(DISTCHECK_DIR)/staged_c_api_test
	$(MAKE) -C $(DISTCHECK_SRC) uninstall PREFIX=/usr/local DESTDIR=../stage
	test -z "$$(find $(DISTCHECK_STAGE)/usr/local \( -type f -o -type l \) -print)"
	@printf 'distcheck passed for %s\n' $(DISTNAME).tar.gz

clean:
	rm -rf $(BIN) $(BUILD)
