.PHONY: build install install-launch-agents smoke-stripe-live smoke-faceless-video

build:
	@./scripts/build-macos-app.sh

install:
	@OS1_SKIP_LAUNCH_AGENTS=1 ./scripts/build-macos-app.sh
	@./scripts/install-launch-agents.sh --reload

install-launch-agents:
	@./scripts/install-launch-agents.sh --reload

smoke-stripe-live:
	@SECRET=$$(security find-generic-password -a "$${USER}" -s OS1_STRIPE_WEBHOOK_SECRET -w 2>/dev/null || true); \
	if [ -z "$$SECRET" ]; then \
		echo "Skipping live Stripe smoke: OS1_STRIPE_WEBHOOK_SECRET is not set in Keychain."; \
		exit 0; \
	fi; \
	OS1_LIVE_SMOKE=1 OS1_STRIPE_WEBHOOK_SECRET="$$SECRET" swift test --filter StripeLiveSmokeTests

smoke-faceless-video:
	@swift test --filter CompanyFacelessVideoPipelineTests/facelessVideoFiveSecondSmokeTestUsesLLMTTSVideoAndRenderProviders
