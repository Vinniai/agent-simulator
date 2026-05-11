agent-sim:
	./build.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f agent-sim AgentSim

.PHONY: agent-sim clean
