# Prisma Cloud + Azure DevOps PR Gates

Reference implementation **and working automation tool** for PR-blocking security gates that combine Prisma Cloud Application Security findings with Azure DevOps branch policies.

This repo documents an end-to-end approach for stopping vulnerable code, hardcoded secrets, and misconfigurations from reaching protected branches — plus the PowerShell tool that applies the configuration across many repos consistently.

---

## What's in here

```
.
├── README.md                          ← you are here
├── tools/
│   ├── Add-PrismaGate.ps1             ← interactive PowerShell tool
│   └── README.md                      ← tool docs, examples, design notes
├── docs/
│   ├── 01-architecture.md             ← two-layer gate model + diagrams
│   ├── 02-setup-guide.md              ← step-by-step setup, both systems
│   ├── 03-enforcement-rules.md        ← Prisma rule design (main + exceptions)
│   ├── 04-branch-policy-design.md     ← ADO branch policy patterns
│   ├── 05-rollout-strategy.md         ← warn-only → enforce phased approach
│   └── 06-lessons-learned.md          ← gotchas, surprises, API quirks
├── runbooks/
│   ├── onboard-new-repo.md
│   ├── rotate-pat-or-oauth.md
│   ├── handle-pr-gate-bypass-request.md
│   └── troubleshoot-webhook-not-firing.md
└── diagrams/
    └── gate-architecture.svg
```

---

## Why this exists

Most "shift left" content stops at "install a scanner." That's not a gate. A real gate requires coordinated configuration across **two independent systems**:

1. **Prisma Cloud Application Security** — scans the PR diff and posts a status check
2. **Azure DevOps branch policies** — requires the status check to pass *and* requires PRs in the first place

Neither alone is sufficient. Skip either side and you have visibility without enforcement, or enforcement without scanning. This repo shows how to wire both together correctly, with the operational details that make the difference between a demo and something a team will actually live with — and provides a PowerShell tool that applies the ADO side at scale.

---

## Quick start

### I just want to use the tool

```powershell
# Set your ADO PAT (needs Code R/W, Project R/W, Identity R, Graph R)
$env:ADO_PAT = "your-pat-here"

# Interactive mode — prompts for project, repos, branch, reviewer group
.\tools\Add-PrismaGate.ps1 -Interactive
```

See [`tools/README.md`](./tools/README.md) for the full reference.

### I want to understand the design first

Read in this order:

1. [Architecture](./docs/01-architecture.md) — understand the two-layer model first
2. [Setup guide](./docs/02-setup-guide.md) — get the integration working end-to-end
3. [Rollout strategy](./docs/05-rollout-strategy.md) — phase the enforcement so devs don't revolt
4. [Lessons learned](./docs/06-lessons-learned.md) — read before you commit to thresholds

---

## Key insights

A few things this repo argues that aren't always obvious going in:

**Prisma Cloud's PR scan is diff-only by default.** Existing branch findings don't fail every subsequent PR — only findings introduced by the PR itself trigger the gate. This is intentional and correct (otherwise teams couldn't ship anything until every existing finding is fixed), but it surprises people who expect the gate to "lock down" a branch. Existing findings need a separate triage workflow.

**Branch policies are independent of the scanner.** Prisma can scream about a finding all day; if your ADO branch policy doesn't require a PR (no minimum reviewers) or doesn't require Prisma's status check, the gate is decoration. A surprising number of "protected" branches accept direct pushes.

**Severity thresholds matter more than which scanner you pick.** Hard-failing on every finding (`Low+`) sounds strict but makes the gate unworkable. Hard-failing on `Critical` only makes most teams comfortable but lets a lot through. The right answer depends on team maturity, codebase age, and remediation capacity — and it should change over time.

**Roll out in three phases:** warn-only → block on Critical → block on High+. Each phase is 30 days. Skipping phases is how you get developer revolt and bypass requests.

**Automating ADO branch policies is harder than the docs suggest.** The PowerShell tool in `tools/` exists because the REST API has many small quirks: JSON serialization edge cases, scope filter requirements, identity GUID vs descriptor formats, paging on group lookups. See `docs/06-lessons-learned.md` for the full list.

---

## What's NOT in here

This repo is intentionally vendor-neutral on the *findings*. It doesn't tell you which CVEs to care about, which secrets patterns to detect, or which IaC misconfigurations matter most for your environment. Those answers are organization-specific and depend on your threat model, compliance posture, and existing risk register.

What's here is the **operational model** — the wiring, the rule design, the rollout pattern, and the automation. Bring your own threat priorities.

---

## License

MIT — use it however helps.

---

## About

Author: Arash Farivarmoheb — IAM & DevSecOps Engineer.

Other portfolio repos:
- [aws-sso-entra-integration](https://github.com/arashfariv/aws-sso-entra-integration) — Enterprise AWS IAM Identity Center + Microsoft Entra ID with SAML/SCIM, lifecycle automation, PIM, ABAC, SCPs
- [azure-devops-pipeline-monitor](https://github.com/arashfariv/azure-devops-pipeline-monitor) — Automated ADO pipeline staleness monitoring with Teams/Email/Power BI
