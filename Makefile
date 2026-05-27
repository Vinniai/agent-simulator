agent-simulator:
	./build.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f agent-simulator AgentSim

.PHONY: agent-simulator clean
