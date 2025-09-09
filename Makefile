# Simple helpers for building and testing the Z-Push Java Shim

.PHONY: help deps \
        test-shim test-rest \
        test-rest-shim test-rest-shim-mock test-rest-shim-env test-rest-shim-live test-rest-autodiscover \
        run-dev test-dev \
        auth-token auth-cookie auth-password \
        verify-ping verify-userinfo verify-credentials get-token-preauth verify-autodiscover

# Path to shim test configuration (override: make test-shim SHIM_CFG=path.yml)
SHIM_CFG ?= test/shim-tests.yml

help:
	@echo "Targets — Mock (Standalone Dev Server)"; \
	 echo "  make run-dev                 # Start dev server on 127.0.0.1:8081 (Ctrl+C to stop)"; \
	 echo "  make test-dev                # Shim tests against dev server (test/shim-tests-dev.yml)"; \
	 echo "  make test-rest-shim-mock     # REST harness shim checks (test/tests-shim.yml). Override base with SHIM_TEST_BASE_URL=http://127.0.0.1:8081"; \
	 echo "  make test-rest-shim-env      # Same as mock; overrides base_url from SHIM_TEST_BASE_URL (likely fails on live — prefer test-rest-shim-live)"; \
	 echo; \
	 echo "Targets — Live (Zimbra mailboxd)"; \
	 echo "  make test-rest-shim-live     # Live shim tests (test/tests-shim-live.yml). Requires SHIM_TEST_BASE_URL/USER/PASSWORD"; \
	 echo "  make verify-credentials      # SOAP + AutoDiscover classification (uses SHIM_TEST_* env)"; \
	 echo "  make verify-autodiscover     # AutoDiscover smoke probe (uses SHIM_TEST_* env)"; \
	 echo "  make auth-token|auth-cookie|auth-password  # One-shot auth helpers"; \
	 echo; \
	 echo "Targets — Generic / Utilities"; \
	 echo "  make deps                    # Install Python deps (requests, pyyaml)"; \
	 echo "  make test-shim               # Dedicated shim test runner (test/run_shim_tests.sh)"; \
	 echo "  make test-rest               # Generic REST harness (REST_CFG overridable; default test/tests.yml)"; \
	 echo "  make verify-ping|verify-userinfo|get-token-preauth  # Helper probes"

deps:
	@echo "Installing Python dependencies (requests, pyyaml)..."
	python3 -m pip install --user requests pyyaml

test-shim:
	@echo "Running shim endpoint tests with $(SHIM_CFG) ..."
	bash test/run_shim_tests.sh "$(SHIM_CFG)"

REST_CFG ?= test/tests.yml

test-rest:
	@cfg="$(REST_CFG)"; \
	if [ -n "$(SHIM_TEST_BASE_URL)" ] && [ "$$cfg" = "test/tests.yml" ]; then \
		echo "Detected SHIM_TEST_BASE_URL; using test/tests-shim-live.yml"; \
		cfg="test/tests-shim-live.yml"; \
	fi; \
	echo "Running generic REST harness with $$cfg ..."; \
	chmod +x test/rest_harness.py || true; \
	python3 test/rest_harness.py "$$cfg"

test-rest-shim:
	@echo "[shim:mock] test/tests-shim.yml defaults to base_url=http://127.0.0.1:8080"; \
	 if [ -n "$(SHIM_TEST_BASE_URL)" ]; then \
	   echo "[shim:mock] Detected SHIM_TEST_BASE_URL=$(SHIM_TEST_BASE_URL) — harness will use this instead of YAML."; \
	   echo "[shim:mock] To force localhost for this run:"; \
	   echo "    SHIM_TEST_BASE_URL=http://127.0.0.1:8080 make test-rest-shim"; \
	 else \
	   echo "[shim:mock] Using YAML base_url (http://127.0.0.1:8080)."; \
	   echo "[shim:mock] To target a live host, set SHIM_TEST_BASE_URL=https://host"; \
	 fi; \
	 $(MAKE) test-rest REST_CFG=test/tests-shim.yml

# Explicit alias to make intent clear
test-rest-shim-mock: test-rest-shim

# Override shim base_url from environment and run REST harness
test-rest-shim-env:
	@tmp_cfg="/tmp/tests-shim-env.$(shell date +%s).yml"; \
	 echo "[shim:env] Overriding base_url in tests-shim.yml to: $(SHIM_TEST_BASE_URL)"; \
	 echo "[shim:env] Note: this still uses mock tests (no auth token). On live mailboxd, only ping will pass."; \
	 echo "[shim:env] For live validation (authenticate/getfolders/etc.), run: make test-rest-shim-live SHIM_TEST_BASE_URL=… SHIM_TEST_USER=… SHIM_TEST_PASSWORD=…"; \
	 cp test/tests-shim.yml "$$tmp_cfg"; \
	 if [ -n "$(SHIM_TEST_BASE_URL)" ]; then \
	 	sed -i "s|^base_url: .*|base_url: \"$(SHIM_TEST_BASE_URL)\"|" "$$tmp_cfg"; \
	 fi; \
	 $(MAKE) test-rest REST_CFG="$$tmp_cfg"; \
	 rm -f "$$tmp_cfg"

test-rest-shim-live:
	@tmp_cfg="/tmp/tests-shim-live.$(shell date +%s).yml"; \
	 echo "[shim:live] Running live shim tests"; \
	 echo "[shim:live] SHIM_TEST_BASE_URL=$(SHIM_TEST_BASE_URL) (overrides YAML if set)"; \
	 echo "[shim:live] Requires SHIM_TEST_USER and SHIM_TEST_PASSWORD in env"; \
	 cp test/tests-shim-live.yml "$$tmp_cfg"; \
	 if [ -n "$(SHIM_TEST_BASE_URL)" ]; then \
	 	sed -i "s|^base_url: .*|base_url: \"$(SHIM_TEST_BASE_URL)\"|" "$$tmp_cfg"; \
	 fi; \
	 $(MAKE) test-rest REST_CFG="$$tmp_cfg"; \
	 rm -f "$$tmp_cfg"

test-rest-shim-auth:
	@$(MAKE) test-rest REST_CFG=test/tests-shim-auth.yml

test-rest-autodiscover:
	@tmp_cfg="/tmp/tests-autodiscover.$(shell date +%s).yml"; \
	cp test/tests-autodiscover.yml "$$tmp_cfg"; \
	if [ -n "$(SHIM_TEST_BASE_URL)" ]; then \
		sed -i "s|^base_url: .*|base_url: \"$(SHIM_TEST_BASE_URL)\"|" "$$tmp_cfg"; \
	fi; \
	BASIC_USER_PASS=$$(printf '%s:%s' "$(SHIM_TEST_USER)" "$(SHIM_TEST_PASSWORD)" | base64); \
	BAD_PW=$${SHIM_TEST_PASSWORD_BAD:-wrong}; \
	BASIC_USER_WRONG=$$(printf '%s:%s' "$(SHIM_TEST_USER)" "$$BAD_PW" | base64); \
	BASIC_USER_PASS="$$BASIC_USER_PASS" BASIC_USER_WRONG="$$BASIC_USER_WRONG" $(MAKE) test-rest REST_CFG="$$tmp_cfg"; \
	rm -f "$$tmp_cfg"

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

verify-userinfo:
	@bash test/verify_userinfo.sh

# Quick SOAP + AutoDiscover classification.
# Usage: make verify-credentials SHIM_TEST_BASE_URL=https://host SHIM_TEST_USER=user@example.com SHIM_TEST_PASSWORD='secret' [INSECURE=1]
VERIFY_INSECURE_ARG := $(if $(INSECURE),--insecure,)
verify-credentials:
	@bash test/verify_credentials.sh $(VERIFY_INSECURE_ARG)

# Obtain user auth token via domain preauth.
get-token-preauth:
	@bash test/get_token_preauth.sh $(VERIFY_INSECURE_ARG)

verify-autodiscover:
	@bash test/check_autodiscover.sh $(VERIFY_INSECURE_ARG)
