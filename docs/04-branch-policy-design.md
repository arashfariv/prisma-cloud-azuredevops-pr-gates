# Branch Policy Design

Azure DevOps branch policies are the enforcement layer that turns Prisma's findings into actual blocked merges. Without correctly-configured branch policies, the scanner has no teeth.

## The minimum viable branch policy

For a protected branch to actually be protected, you need at minimum:

| Setting | Value | Why |
|---------|-------|-----|
| Require a minimum number of reviewers | ON, minimum 1 | Forces all changes through PRs. Without this, direct push is allowed. |
| Status Checks → Prisma Cloud / Code analysis | Required | Makes Prisma's verdict block-or-allow merges. |

That's it for the critical path. Everything else is refinement.

## What "protected" actually means in ADO

A branch is only protected to the extent that branch policies require things. Common misconceptions:

| Misconception | Reality |
|---------------|---------|
| "Default branches are automatically protected." | False. New repos accept direct push to main unless policies are configured. |
| "Auto-included reviewers protect the branch." | False. They're added to PRs *if a PR is opened* — they don't force PRs to be opened. |
| "Status checks block bad merges." | Only when configured as Required *and* a PR exists. |

Audit before you assume. The `Branches` view of any repo shows which branches have policies (look for the lock icon), but doesn't tell you if those policies are sufficient.

## Recommended policy patterns

### Pattern A: Standard protected branch

The default for any production-ish branch.

```
✓ Require a minimum number of reviewers
  Minimum: 1
  Allow requestors to approve their own changes: OFF
  Prohibit the most recent pusher from approving their own changes: ON
  When new changes are pushed: Reset all code reviewer votes
  Allow completion even if some reviewers vote "Waiting" or "Reject": OFF

✓ Check for comment resolution
  Required

✓ Status Checks
  • Prisma Cloud / Code analysis: Required
  • [optional: Build Validation results: Required]

✓ Build Validation
  Required (if a CI pipeline exists)

✓ Limit merge types
  Squash merge: allowed
  Other types: per team preference
```

### Pattern B: Strict protected branch

For critical/regulated repos. Tighter than Pattern A.

```
✓ Require a minimum number of reviewers
  Minimum: 2
  Allow requestors to approve their own changes: OFF
  Prohibit the most recent pusher from approving their own changes: ON
  When new changes are pushed: Reset all code reviewer votes
  Allow completion even if some reviewers vote "Waiting" or "Reject": OFF
  
✓ Check for comment resolution
  Required

✓ Status Checks
  • Prisma Cloud / Code analysis: Required
  • Build Validation: Required
  
✓ Automatically included reviewers
  Group: [Security Team]
  Required: yes
  
✓ Build Validation
  Required, must pass

✓ Limit merge types
  Squash merge only (linear history for audit)
```

### Pattern C: Small-team allowance

For small teams where the only people who can approve are also the people who push code. Honest tradeoff with documented justification.

```
✓ Require a minimum number of reviewers
  Minimum: 1
  Allow requestors to approve their own changes: ON   ← documented exception
  Prohibit the most recent pusher from approving their own changes: ON
  
✓ Status Checks
  • Prisma Cloud / Code analysis: Required
```

The "Prohibit the most recent pusher" setting partially compensates for self-approval being allowed. Document why this pattern was chosen — it's a real tradeoff and shouldn't be invisible.

## The bypass permissions question

ADO has two bypass permissions worth auditing:

- **Bypass policies when pushing** — allows direct push to a protected branch
- **Bypass policies when completing pull requests** — allows merging despite failed required checks

These should be:

- **Restricted to a small named group** (security/SRE leadership, not "all admins")
- **Audited regularly** — who has it, when did they get it, when was it last used
- **Used sparingly** — every bypass should produce an artifact (issue, ticket, log)

Find current grantees in: Project Settings → Repositories → [repo] → Security → look up specific permissions.

## Required vs optional status checks

When adding a status check, ADO offers Required vs Optional:

- **Required** — must succeed for merge
- **Optional** — visible on the PR but doesn't block merge

For a real gate, Prisma must be Required. Optional checks are visibility theater.

But! There's a useful pattern for rollout: start with Optional during warn-only phase, then switch to Required when ready to enforce. Devs see the check, get used to it, before it actually blocks anything.

## Build validation vs status checks

Two different mechanisms in ADO branch policies:

- **Build Validation** — runs an ADO pipeline (CI build) and requires it to succeed
- **Status Checks** — accepts status posts from external services (like Prisma)

For Prisma:

- **Status Checks** is the standard path — Prisma posts status directly via webhook
- **Build Validation** could be used if Prisma is invoked via a pipeline task instead of native VCS integration

If you're running both (a CI pipeline that includes a Prisma task AND the native Prisma integration), be aware they're two separate scans. Pick one as the source of truth or you'll have confusing dual statuses.

## Branch policy as code

Configuring branch policies via UI works for one repo. For dozens or hundreds, automate.

ADO's REST API supports branch policy CRUD. Common policy type IDs:

| Policy | Type ID |
|--------|---------|
| Minimum reviewers | `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` |
| Build validation | `0609b952-1397-4640-95ec-e00a01b2c241` |
| Status check | `cbdc66da-9728-4af8-aada-9a5a32e4a226` |
| Comment resolution | `c6a1889d-b943-4856-b76f-9e46bb6b0df2` |
| Required reviewer (auto-include) | `fd2167ab-b0be-447a-8ec8-39368250530e` |

A working PowerShell tool that applies policies via API is in [`tools/Add-PrismaGate.ps1`](../tools/Add-PrismaGate.ps1). See [`tools/README.md`](../tools/README.md) for usage.

For real rollouts, treat branch policies as code:

- Store policy definitions in a config repo
- Apply via CI/CD (pipeline that calls ADO API)
- Track changes via git history
- Review as PRs

This is overkill for 5 repos, essential for 50+.

## Drift detection

Branch policies drift over time. New repos get created without policies. People disable settings during emergencies and forget to re-enable. Audit periodically.

Useful audit queries:

- Which repos have NO branch policies?
- Which repos have policies but minimum reviewers is 0 or unset?
- Which protected branches don't have Prisma as a required status check?
- Who has used "Bypass policies" permissions in the last 30 days?

These can be answered via the ADO API. Build a recurring report.

## Common branch policy mistakes

### "All branches" vs specific branch

Branch policies are configured per branch, not "all branches." A policy on `main` doesn't apply to `master`, `release/*`, or `develop`. Configure each protected branch explicitly.

For repos with predictable branch patterns (e.g., `release/*`), use **branch name patterns** in policy scope.

### Required status check that doesn't exist

If you select a status check name that no service ever posts, the PR will sit forever waiting. Make sure Prisma has actually posted a status to the repo at least once before adding it as Required.

### Reviewer group that contains the requestor

If your "Code Review Approvers" group includes the people who push code, and self-approval is on, the gate is decoration. Either:

- Remove pushers from the approver group, or
- Turn off self-approval, or
- Acknowledge the tradeoff and document it (Pattern C above)

### "When new changes are pushed: Don't reset votes"

Default is to reset votes on new pushes. Sounds annoying but is correct — a reviewer approved version N, then version N+1 was pushed. The N+1 version hasn't been reviewed. Don't auto-carry-forward approval.

If your team disabled this for convenience, you've broken the review gate.
