CANARY = $(CURDIR)/../..

.PHONY: test

# Smoke test: stage a throwaway app pointing at canary's counter
# example, ship it, assert dist/<name> exists and is executable.
test:
	@set -e; \
	smoke=$$(mktemp -d); \
	mkdir -p $$smoke/src; \
	cp $(CANARY)/examples/counter.scm $$smoke/src/smoke.scm; \
	printf '(canary-app (name "smoke") (load-paths "src"))\n' > $$smoke/canary-app.scm; \
	cd $$smoke && $(CURDIR)/canary-build ship; \
	test -x $$smoke/dist/smoke && echo "OK: ship produced dist/smoke"; \
	rm -rf $$smoke
