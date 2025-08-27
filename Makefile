# Simple helpers for building and testing the Z-Push Java Shim

.PHONY: help deps test-shim test-rest test-rest-shim run-dev test-dev auth-token auth-cookie auth-password verify-ping

# Path to shim test configuration (override: make test-shim SHIM_CFG=path.yml)
SHIM_CFG ?= test/shim-tests.yml

help:
	@echo "Useful targets:"
	@echo "  make deps         # Install Python deps for tests (requests, pyyaml)"
	@echo "  make test-shim    # Run shim endpoint tests using $$SHIM_CFG ($(SHIM_CFG))"
	@echo "  make test-rest    # Run generic REST harness (REST_CFG overridable; default test/tests.yml)"
	@echo "  make test-rest-shim # Run REST harness against shim endpoints (uses test/tests-shim.yml)"
	@echo "  make run-dev      # Start standalone dev server on 127.0.0.1:8081 (Ctrl+C to stop)"
	@echo "  make test-dev     # Run tests against the dev server (uses test/shim-tests-dev.yml)"
	@echo "  make auth-token   # One-shot SOAP login + shim authenticate (header token)"
	@echo "  make auth-cookie  # Authenticate using cookie + optional CSRF from soap.json"
	@echo "  make auth-password# Authenticate using username/password (URL-encoded)"
	@echo "  make verify-ping  # POST action=ping to shim endpoint and print result"

deps:
	@echo "Installing Python dependencies (requests, pyyaml)..."
	python3 -m pip install --user requests pyyaml

test-shim:
	@echo "Running shim endpoint tests with $(SHIM_CFG) ..."
	bash test/run_shim_tests.sh "$(SHIM_CFG)"

REST_CFG ?= test/tests.yml

test-rest:
	@echo "Running generic REST harness with $(REST_CFG) ..."
	chmod +x test/rest_harness.py || true
	python3 test/rest_harness.py $(REST_CFG)

test-rest-shim:
	@$(MAKE) test-rest REST_CFG=test/tests-shim.yml

run-dev:
	@echo "Starting standalone dev server (no Zimbra required) ..."
	ant run-dev

test-dev:
	@echo "Testing against standalone dev server ..."
	$(MAKE) test-shim SHIM_CFG=test/shim-tests-dev.yml

auth-token:
	@bash test/shim-auth-token.sh

auth-cookie:
	@bash test/shim-auth-cookie.sh

auth-password:
	@bash test/shim-auth-password.sh

# Simple ping verification to the shim endpoint.
# Override BASE_URL or SHIM_PATH if necessary.
BASE_URL ?= http://localhost:8080
SHIM_PATH ?= /service/extension/zpush-shim

verify-ping:
	@url="$(BASE_URL)$(SHIM_PATH)"; \
	echo "POST $$url action=ping"; \
	resp=$$(curl -sS -X POST -d 'action=ping' "$$url" || true); \
	echo "$$resp"; \
	echo "$$resp" | grep -q '"status":"ok"' && echo "[PASS] ping" || { echo "[FAIL] ping"; exit 1; }
