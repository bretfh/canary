GUILE ?= guile
GUILD ?= guild
BUILD_DIR ?= build
SCM_FILES := $(shell find canary -name '*.scm')
GO_FILES := $(patsubst canary/%.scm,$(BUILD_DIR)/canary/%.go,$(SCM_FILES))
TEST_FILES := $(wildcard tests/test-*.scm)

.PHONY: all compile test lint clean repl tool tool-install tool-test

all: compile

# Build tool — produces static binaries of canary apps.  See
# tools/build/README.md for the app-author workflow.
tool:
	@command -v guix >/dev/null || { echo "guix not on PATH"; exit 1; }
	@echo "canary-build ready: $(CURDIR)/tools/build/canary-build"

tool-install:
	install -Dm755 tools/build/canary-build $(DESTDIR)$(HOME)/.local/bin/canary-build
	@echo "installed: ~/.local/bin/canary-build"

tool-test: compile
	$(MAKE) -C tools/build test

compile: $(GO_FILES)

$(BUILD_DIR)/canary/%.go: canary/%.scm
	@mkdir -p $(dir $@)
	$(GUILD) compile -L . -o $@ $<

test:
	@for f in $(TEST_FILES); do \
		echo "==> $$f"; \
		$(GUILE) -L . "$$f" || exit 1; \
	done

lint:
	@! grep -rn '\\x1b' canary --include='*.scm' \
		| grep -v 'backend-ansi.scm\|terminal.scm' \
		|| (echo "ANSI escape codes found outside backend-ansi/terminal" && exit 1)

clean:
	rm -rf $(BUILD_DIR)

repl:
	$(GUILE) -L . --listen=37147
