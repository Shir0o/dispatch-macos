.PHONY: verify

verify:
	swift build --build-tests
	swift test --no-parallel
