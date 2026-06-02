.PHONY: help shutdown startup

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

shutdown: ## Gracefully power off the whole rack (detaches Longhorn volumes first)
	./scripts/rack/shutdown

startup: ## Bring the cluster back up: wait for nodes, then uncordon
	./scripts/rack/startup
