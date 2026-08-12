# Convenience wrapper. Everything here runs on a Mac with Xcode; nothing needs AWS.
.DEFAULT_GOAL := help
APP := app/build/Build/Products/Debug-iphonesimulator/SimDensity.app
LEVELS ?= 1 2 4 8
REPEATS ?= 3

.PHONY: help bootstrap sweep smoke analyze clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Install tools, generate project, build the app once
	./scripts/bootstrap.sh

smoke: ## Fastest end-to-end check: N=1,2 once each
	./harness/sweep.sh --app "$(APP)" --levels "1 2" --repeats 1

sweep: ## Run the density sweep (override LEVELS / REPEATS)
	./harness/sweep.sh --app "$(APP)" --levels "$(LEVELS)" --repeats $(REPEATS)

analyze: ## Summarize the most recent results.csv
	@latest=$$(ls -td results/*/ 2>/dev/null | head -1); \
	  test -n "$$latest" && python3 harness/analyze.py "$$latest/results.csv" || echo "no results yet — run 'make sweep'"

clean: ## Remove build output and results
	rm -rf app/build app/SimDensity.xcodeproj results
