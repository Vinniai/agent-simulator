agent-sim:
	./build.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f agent-sim Baguette

.PHONY: agent-sim clean
