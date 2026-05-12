.PHONY: smoke-stripe-live smoke-faceless-video

smoke-stripe-live:
	@SECRET=$$(security find-generic-password -a "$${USER}" -s OS1_STRIPE_WEBHOOK_SECRET -w 2>/dev/null || true); \
	if [ -z "$$SECRET" ]; then \
		echo "Skipping live Stripe smoke: OS1_STRIPE_WEBHOOK_SECRET is not set in Keychain."; \
		exit 0; \
	fi; \
	OS1_LIVE_SMOKE=1 OS1_STRIPE_WEBHOOK_SECRET="$$SECRET" swift test --filter StripeLiveSmokeTests

smoke-faceless-video:
	@swift test --filter CompanyFacelessVideoPipelineTests/facelessVideoFiveSecondSmokeTestUsesLLMTTSVideoAndRenderProviders
