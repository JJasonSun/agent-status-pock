.PHONY: bridge widget test install uninstall

bridge:
	cd bridge && swift build -c release

unit:
	cd bridge && swift test

widget:
	cd widget && ./build.sh

# build.sh always emits AgentTouchBar.pock plus matching .pkarchive files.
package: widget
	@echo "Archives are built by widget/build.sh; see widget/dist/."

test: unit bridge widget
	@set -e; (cd bridge && AGENTBRIDGE_PORT=39390 AGENTBRIDGE_STATE=/tmp/ab-test-state.json exec ./.build/release/AgentBridge > /tmp/ab-test.log 2>&1) & \
	pid=$$!; trap 'kill $$pid 2>/dev/null || true' EXIT; set -e; \
	for attempt in $$(seq 1 20); do curl -fsS localhost:39390/v1/health > /dev/null && break; test $$attempt -lt 20 || { cat /tmp/ab-test.log >&2; exit 1; }; sleep 0.25; done; \
	echo "bridge health: OK"; \
	curl -fsS -X POST localhost:39390/v1/event -d '{"agent":"claude","event":"tool_start","tool":"Edit","detail":"x"}' > /dev/null; echo "event: OK"; \
	curl -fsS localhost:39390/v1/state | grep -q "working"; echo "state: OK"; \
	for attempt in $$(seq 1 20); do grep -q '"working"' /tmp/ab-test-state.json 2>/dev/null && break; test $$attempt -lt 20 || { echo "state file never showed working" >&2; exit 1; }; sleep 0.1; done; \
	echo "state file: OK"; \
	curl -fsS localhost:39390/v1/state | grep -q '"memory"'; echo "memory: OK"; \
	echo '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/hook.swift"}}' \
	  | AGENTBRIDGE_URL=http://127.0.0.1:39390 ./bridge/.build/release/AgentBridgeHook claude; \
	for attempt in $$(seq 1 20); do grep -q 'hook.swift' /tmp/ab-test-state.json 2>/dev/null && break; test $$attempt -lt 20 || { echo "swift hook never reached the bridge" >&2; exit 1; }; sleep 0.1; done; \
	echo "swift hook: OK"
	@cd widget && swiftc -o dist/smoke-test tests/smoke.swift && ./dist/smoke-test
	@cd widget && swiftc -parse-as-library -o dist/render-test tests/render.swift ../SharedModels/Sources/AgentBridgeModels/Models.swift Sources/*.swift -I dist -L dist/lib -lPockKit -Xlinker -rpath -Xlinker "$$PWD/dist/lib" && ./dist/render-test | grep -v "^{\"ok"

install:
	./install.sh

uninstall:
	./uninstall.sh
