#!/usr/bin/env bash
# Require the "Full Project Check" CI job to pass before anything merges to main.
#
# Background (issue #354): renovate PR #346 (Flutter 3.44.7, whose cirruslabs
# image had not been published) was auto-merged one second BEFORE the
# "Full Project Check" job even started -- so the failing check couldn't block
# the merge. The two active branch rulesets on main required a pull request but
# did NOT contain a required_status_checks rule, so auto-merge had nothing to
# wait for.
#
# This script patches ruleset id 18026250 (name "main", targets ~DEFAULT_BRANCH)
# so that "Full Project Check" is required before merge. With that in place,
# auto-merge waits for CI, and broken renovate PRs stay open with a red check
# until a human intervenes.
#
# Requires: gh CLI authenticated as a repo admin (branch protection settings
# need admin scope on the repository).
# Idempotent: safe to re-run; replaces any existing required_status_checks
# rule with the canonical one below.
set -euo pipefail

REPO="guettli/sharedinbox"
RULESET_ID=18026250
CHECK_CONTEXT="Full Project Check"

# Resolve the GitHub Actions app id dynamically instead of hardcoding 15368.
ACTIONS_APP_ID=$(gh api /apps/github-actions --jq '.id')

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

gh api "repos/$REPO/rulesets/$RULESET_ID" > "$tmp"

# PUT accepts only the mutable fields; drop metadata GitHub adds on read
# (_links, id, node_id, source, source_type, created_at, updated_at,
# current_user_can_bypass). Then replace any pre-existing
# required_status_checks rule with our canonical one.
jq --arg ctx "$CHECK_CONTEXT" --argjson app "$ACTIONS_APP_ID" '
  {
    name,
    target,
    enforcement,
    conditions,
    bypass_actors: (.bypass_actors // []),
    rules: (
      (.rules | map(select(.type != "required_status_checks"))) +
      [{
        type: "required_status_checks",
        parameters: {
          strict_required_status_checks_policy: true,
          do_not_enforce_on_create: false,
          required_status_checks: [
            { context: $ctx, integration_id: $app }
          ]
        }
      }]
    )
  }
' "$tmp" | gh api --method PUT "repos/$REPO/rulesets/$RULESET_ID" --input - > /dev/null

echo "OK: ruleset $RULESET_ID now requires '$CHECK_CONTEXT' to pass before merge on main."
