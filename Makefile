# Inference service + OCaml build helpers.
PY      ?= sidecar/.venv/bin/python
# INFER_* (not PORT/HOST): web launchers often export PORT for their own server
INFER_HOST ?= 127.0.0.1
INFER_PORT ?= 8766
DEVICE  ?= cpu

.PHONY: up up-bg down health smoke build test

up:            ## run the inference service in the foreground
	INFER_DEVICE=$(DEVICE) $(PY) -m uvicorn inference.app:app --host $(INFER_HOST) --port $(INFER_PORT)

up-bg:         ## run it in the background (log: inference/service.log)
	@if curl -sf http://$(INFER_HOST):$(INFER_PORT)/health >/dev/null; then echo "inference service already running on $(INFER_HOST):$(INFER_PORT)"; exit 0; fi; \
	$(MAKE) --no-print-directory _start-bg

_start-bg:
	INFER_DEVICE=$(DEVICE) nohup $(PY) -m uvicorn inference.app:app --host $(INFER_HOST) --port $(INFER_PORT) > inference/service.log 2>&1 & echo $$! > inference/service.pid.new
	@echo "started (pid $$(cat inference/service.pid.new)) on $(INFER_HOST):$(INFER_PORT); waiting for /health"; \
	for i in $$(seq 1 180); do \
	  curl -sf http://$(INFER_HOST):$(INFER_PORT)/health >/dev/null && { mv inference/service.pid.new inference/service.pid; curl -s http://$(INFER_HOST):$(INFER_PORT)/health; echo; exit 0; }; \
	  kill -0 $$(cat inference/service.pid.new) 2>/dev/null || { echo "inference service exited during startup:"; tail -3 inference/service.log; rm -f inference/service.pid.new; exit 1; }; \
	  sleep 2; done; kill $$(cat inference/service.pid.new) 2>/dev/null; rm -f inference/service.pid.new; echo "inference service did not become healthy in 6 minutes; see inference/service.log"; exit 1

down:
	-kill $$(cat inference/service.pid) 2>/dev/null; rm -f inference/service.pid

health:
	@curl -s http://$(INFER_HOST):$(INFER_PORT)/health; echo

smoke:         ## 3-ticker smoke test against a running service
	$(PY) inference/tools/smoke_test.py --url http://$(INFER_HOST):$(INFER_PORT)

build:
	opam exec --switch=fp -- dune build 2>&1 | grep -v "ld: warning" || true

test:
	opam exec --switch=fp -- dune test 2>&1 | grep -v "ld: warning"
