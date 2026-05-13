# Enforcement Rules

Prisma Cloud's enforcement rules are deceptively simple — sliders for severity thresholds across categories. The hard part is choosing thresholds that catch real problems without making the gate unworkable.

## The rule model

Two rule types:

**Main rule (global)**
- Applies to all onboarded repos by default
- Can't be deleted
- Can't be scoped to specific repos
- Edit thresholds with care — changes affect everything

**Exception rules (per-repo or per-group)**
- Apply to specific repository sets
- Have their own thresholds, independent of the main rule
- Can be created, edited, deleted freely
- Use these for anything that needs custom enforcement

Mental model: main rule = baseline for the whole tenant, exceptions = override for specific repos.

## Threshold categories

Five categories, each with three response levels:

| Category | What it covers |
|----------|---------------|
| **Vulnerabilities** | Software composition analysis (SCA) — known CVEs in dependencies |
| **Licenses** | License compliance (GPL, copyleft, etc.) |
| **IaC** | Infrastructure-as-code misconfigurations (Terraform, ARM, K8s, CloudFormation) |
| **Weaknesses** | SAST — code-level vulnerability patterns (currently in development as of writing) |
| **Secrets** | Hardcoded credentials, API keys, tokens |

For each category, three response levels:

| Level | Behavior |
|-------|----------|
| **Hard Fail** | Returns failed status, blocks PR merge in ADO (when configured as required) |
| **Soft Fail** | Returns warning status, doesn't block — flagged for awareness |
| **Comments Bot** | Posts inline comments on the PR, no status impact |

Severity threshold sliders go: Off → Info → Low → Medium → High → Critical. Setting Hard Fail to "Low" means anything Low severity or higher hard-fails.

## Recommended threshold patterns

### Pattern A: New repo, conservative onboarding

For a repo being onboarded for the first time. Goal: prove the gate works without immediate disruption.

| Category | Hard Fail | Soft Fail | Comments Bot |
|----------|-----------|-----------|--------------|
| Vulnerabilities | Critical | High | Medium |
| Licenses | Critical | High | Medium |
| IaC | High | Medium | Low |
| Secrets | Low | — | — |
| Weaknesses | (disabled) | — | — |

Why these values:

- **Critical-only on Vulnerabilities** keeps PRs flowing while team builds triage muscle
- **Hard Fail on Secrets at Low** is non-negotiable — any leaked credential is a real problem
- **IaC at High** catches the obvious (public buckets, missing encryption) without nitpicking style issues

### Pattern B: Mature repo, standard enforcement

After 30+ days of warn-only or conservative enforcement. Team understands findings, has triage capacity.

| Category | Hard Fail | Soft Fail | Comments Bot |
|----------|-----------|-----------|--------------|
| Vulnerabilities | High | Medium | Low |
| Licenses | High | Medium | Low |
| IaC | Medium | Low | Low |
| Secrets | Low | — | — |
| Weaknesses | High (when available) | Medium | Low |

### Pattern C: Critical / regulated repo

For repos with elevated risk — payment processing, PII handling, public-facing APIs. Stricter than Pattern B.

| Category | Hard Fail | Soft Fail | Comments Bot |
|----------|-----------|-----------|--------------|
| Vulnerabilities | Medium | Low | Low |
| Licenses | High | Medium | Low |
| IaC | Medium | Low | Low |
| Secrets | Low | — | — |
| Weaknesses | Medium (when available) | Low | Low |

Tighter thresholds mean more friction. Make sure the team has the triage capacity to support it.

## What NOT to do

### Don't go to Hard Fail on Low+ across all categories on Day 1

Sounds strict, fails in practice. Every PR will fail. Devs will request bypass. Bypass becomes routine. Gate dies.

### Don't enforce the same thresholds tenant-wide

The main rule applies everywhere. If you tighten Vulnerabilities to High on the main rule, every repo in the tenant inherits it — including ones that aren't ready. Use exceptions for differential enforcement.

### Don't ignore Soft Fail and Comments Bot

These are your warn-mode dials. A finding at Soft Fail still surfaces in the dashboard and PR comments — devs see it, triage it, fix it. You build muscle memory before tightening to Hard Fail.

## Diff-only behavior — what to know

Prisma's PR scans evaluate the **diff**, not the full branch state. Implications:

- Existing findings on the target branch don't auto-fail every subsequent PR
- A clean PR diff passes even if the target branch has open findings
- A finding shows up at PR time when the PR introduces it, or touches files that surface it

This is the right behavior. If existing findings blocked every PR, teams couldn't ship anything until 100% of debt is resolved — which is never. Pretending you can fix everything before merging anything is fantasy.

The implication: **existing findings need a separate workflow**. Three patterns:

1. **Suppress with business justification** — "awaiting upstream patch from Microsoft" or "false positive, accepted risk." Suppressed findings don't appear in enforcement.
2. **Fix on a remediation backlog** — track in your normal work tracking system, prioritize against other engineering work.
3. **Accept and document** — for findings that are real but won't be fixed (deprecated repo, legacy code, planned retirement). Document the decision.

The gate handles the future. Triage handles the past.

## Exception rules in practice

### Single-repo exception

The most common case. One repo needs different thresholds than the tenant default.

**Example:** `payments-service` needs Pattern C (strict), everything else stays on Pattern A.

In Prisma:
1. Open Enforcement (hamburger menu on a project page)
2. Add Exception
3. Description: `payments-service - critical repo`
4. Repositories: select `payments-service`
5. Configure sliders to Pattern C values
6. Save

### Multi-repo exception

Group several repos under one exception when they share enforcement requirements.

**Example:** All public-facing API repos need Pattern B.

In Prisma:
1. Add Exception
2. Description: `Public-facing APIs - standard enforcement`
3. Repositories: select all relevant repos
4. Configure Pattern B
5. Save

If the list grows, you may want to use repo labels for cleaner management — but the simple selection list works fine for small numbers.

### Per-environment exception

When different branches of the same repo need different rules (rare but valid).

This is harder. Prisma's exception is per-repo, not per-branch. Workarounds:

- Run separate scans of each branch (set up multiple integrations or branch configs)
- Use branch policies in ADO to differentiate enforcement at the merge layer rather than the scan layer
- Accept that scan-level differentiation isn't natively supported and address at the policy layer

## Reviewing rules over time

Rules should evolve. Suggested cadence:

- **Weekly (first month):** review which findings are firing the gate. Adjust thresholds for noise.
- **Monthly (steady state):** review enforcement metrics — how often is the gate firing? What's the average time-to-fix? Are bypass requests increasing?
- **Quarterly:** revisit threshold strategy. Should you tighten? Loosen? Add categories that were skipped?

Document threshold changes with reasons. "Bumped Vulnerabilities Hard Fail from Critical to High after 30 days of warn-only data showed average of 1 High/week with consistent fix-within-48-hour pattern" is a defensible decision. "We tightened the rules" is not.

## Suppression workflow

Findings can be suppressed in Prisma Cloud rather than fixed. Suppression should be deliberate, documented, and reviewed.

Reasons to suppress:

- **No fix available** — vendor hasn't published a patch yet
- **False positive** — finding doesn't apply to your usage
- **Accepted risk** — finding is real but compensating controls exist
- **Deprecated** — code is being retired, not worth fixing

Each suppression should record:

- Who approved it
- Why it was suppressed
- When it should be reviewed again (set a date)
- What compensating control exists if accepted-risk

Without these, suppressions accumulate as silent risk. With them, suppressions are a documented engineering decision.
