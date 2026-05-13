# Architecture

## The two-layer model

A working PR security gate is the intersection of two systems:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Azure DevOps Branch Policy                        │
│  ─────────────────────────────────────                      │
│  • Requires a minimum number of reviewers (forces PRs)      │
│  • Requires Prisma's status check to be Required            │
│  • Restricts "Bypass policies" permissions                  │
└─────────────────────────────────────────────────────────────┘
                            │
                            │  PR opened
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Prisma Cloud Enforcement                          │
│  ───────────────────────────────────                        │
│  • Scans the PR diff                                        │
│  • Evaluates findings against enforcement rules             │
│  • Posts HARD_FAIL / SOFT_FAIL / PASS status to ADO         │
└─────────────────────────────────────────────────────────────┘
                            │
                            │  Status returned to ADO
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 1 (again): Branch Policy evaluates required check    │
│  ─────────────────────────────────────────────────          │
│  • PASS → merge button enabled (pending human reviewer)     │
│  • HARD_FAIL → merge button disabled                        │
└─────────────────────────────────────────────────────────────┘
```

Both layers must be configured. Skip either side and the gate doesn't gate.

## Why two layers

| If you have... | Result |
|----------------|--------|
| Prisma only, no ADO branch policy | Findings appear in dashboard. Devs can merge whatever they want. |
| ADO branch policy only, no Prisma status as required | PRs require reviewers, but Prisma's findings don't block merges. |
| **Both configured correctly** | PRs are required. Prisma evaluates them. Findings can block merges. |
| Both configured, but main allows direct push | Devs bypass everything by pushing direct to main. |

The fourth row is the most common failure mode. Branch protection settings drift over time, especially as new repos get created without consistent governance. **Audit existing branch policies before you trust them.**

## Detection vs prevention

A third layer exists — **scheduled scans** of the protected branch — but it's detection, not prevention. Findings show up in the dashboard hours after they land. This is your safety net for:

- Direct pushes by users with bypass permissions
- Findings that emerge later (CVEs published after a merge)
- Issues in code that never went through a PR (legacy commits)

Treat scheduled scans as an audit/alerting layer, not a gate. The gate is what blocks bad code at PR time.

## Severity thresholds in this model

Prisma Cloud's enforcement supports three response levels per finding category:

| Response | What it does | When to use |
|----------|--------------|-------------|
| **Hard Fail** | Returns failed status, blocks merge | Critical/High severity, secrets, license violations |
| **Soft Fail** | Returns warning status, allows merge | Medium severity, advisory findings |
| **Comments Bot** | Posts inline PR comments only | Low severity, informational |

A typical mature configuration might look like:

| Category | Hard Fail | Soft Fail | Comments Bot |
|----------|-----------|-----------|--------------|
| Vulnerabilities (SCA) | High+ | Medium+ | Low+ |
| Licenses | Critical | High+ | Medium+ |
| IaC | High+ | Medium+ | Low+ |
| Secrets | Low+ | n/a | n/a |
| Weaknesses (SAST) | TBD (module under development) | — | — |

**Why Secrets sits at Low+:** any leaked credential is a problem regardless of "severity." Treat all secrets as block-on-detect.

**Why Vulnerabilities are not Low+:** transitive dependency CVEs accumulate fast. Hard-failing on Low creates noise that drowns out the actual threats. Start at High and tighten only when triage capacity is proven.

## Scoping rules

Prisma Cloud uses a "main rule + exception" model:

- **Main rule** applies to all onboarded repos by default. Cannot be deleted or scoped.
- **Exception rules** apply to specific repository sets, with their own thresholds.

This is how you have a strict gate on `production-payments-api` and a permissive one on `experimental-research-tool` in the same tenant.

## Diff-only behavior (important)

PR scans evaluate the diff, not the full branch. This means:

- Existing findings on the target branch are not re-evaluated for every PR
- A PR with a clean diff passes even if the target branch has open findings
- Findings introduced by the PR (or re-surfaced by changes to the same files) trigger enforcement

Implication: existing findings need a separate workflow (suppress with justification, fix on a remediation backlog, or accept with documented risk). The gate doesn't force them to be addressed — it only stops new ones.

## What about pipeline gates?

A pipeline-based gate (Prisma scan task in `azure-pipelines.yml`, blocking the build) is an alternative to PR status checks. Pros and cons:

| | PR Status Check | Pipeline Task |
|---|---|---|
| **Where it runs** | Prisma's infrastructure | Your ADO build agent |
| **Setup** | One-time, integration-level | Per-pipeline YAML edit |
| **Blocking mechanism** | ADO required status check | ADO required build validation |
| **Visibility** | Status check on PR | Build log + test result |
| **Best for** | Org-wide consistent gates | Per-repo customization |

For most orgs, PR status checks scale better. Pipeline tasks are useful when the team needs custom scan parameters, gate logic, or wants the scan in their existing CI traceability.

This repo focuses on PR status checks. See [setup guide](./02-setup-guide.md) for pipeline task option.
