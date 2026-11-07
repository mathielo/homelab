.PHONY: help shutdown startup ytdl pihole-ha-check article-check-status article-check-enable article-check-disable

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

shutdown: ## Gracefully power off the whole rack (detaches Longhorn volumes first)
	./scripts/rack/shutdown

startup: ## Bring the cluster back up: wait for nodes, then uncordon
	./scripts/rack/startup

ytdl: ## Create new job to manually triger ytdl-sub run
	kubectl delete job -n media ytdl-sub-manual --ignore-not-found
	kubectl create job -n media --from=cronjob/ytdl-sub ytdl-sub-manual

pihole-ha-check: ## Show which Pi-hole node currently holds the VIP (master)
	@for h in pihole-01 pihole-02; do \
		ssh $$h "hostname; ip -4 addr show eth0 | grep -q 10.10.53.53 && echo '  -> MASTER (holds VIP)' || echo '  -> backup'"; \
	done

article-check-status: ## Show whether the SABnzbd article check is enabled, plus its recent log
	@kubectl exec -n media deploy/sabnzbd -c article-check -- bash -c 'if [ -f /state/enabled ]; then echo enabled; else echo disabled; fi'
	@kubectl logs -n media deploy/sabnzbd -c article-check --tail=20

article-check-enable: ## Enable the article check (first cycle starts within 10 min)
	kubectl exec -n media deploy/sabnzbd -c article-check -- touch /state/enabled

article-check-disable: ## Disable the article check (a running cycle finishes first)
	kubectl exec -n media deploy/sabnzbd -c article-check -- rm -f /state/enabled
