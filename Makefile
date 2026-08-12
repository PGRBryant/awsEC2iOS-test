# Convenience wrapper. Everything here runs on a Mac with Xcode; nothing needs AWS.
.DEFAULT_GOAL := help
APP := app/build/Build/Products/Debug-iphonesimulator/SimDensity.app
LEVELS ?= 1 2 4 8
REPEATS ?= 3

.PHONY: help bootstrap sweep smoke dryrun uitest analyze clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install tools, generate project, build the app once
	./scripts/bootstrap.sh

smoke: ## Fastest end-to-end check: N=1,2 once each
	./harness/sweep.sh --app "$(APP)" --levels "1 2" --repeats 1

dryrun: ## Exercise the harness with mock simctl — works on any OS, no Xcode
	./harness/sweep.sh --dry-run --levels "1 2 4" --repeats 1 --boot-timeout 10 --launch-timeout 4

uitest: ## One-time interactivity check on a single simulator (XCUITest)
	cd app && xcodegen generate && xcodebuild test -project SimDensity.xcodeproj \
	  -scheme SimDensity -destination 'platform=iOS Simulator,name=iPhone 15' \
	  -derivedDataPath build CODE_SIGNING_ALLOWED=NO

sweep: ## Run the density sweep (override LEVELS / REPEATS)
	./harness/sweep.sh --app "$(APP)" --levels "$(LEVELS)" --repeats $(REPEATS)

analyze: ## Summarize the latest results + write report.md next to the CSV
	@latest=$$(ls -td results/*/ 2>/dev/null | head -1); \
	  test -n "$$latest" && python3 harness/analyze.py "$$latest/results.csv" --report "$$latest/report.md" || echo "no results yet — run 'make sweep'"

clean: ## Remove build output and results
	rm -rf app/build app/SimDensity.xcodeproj results
