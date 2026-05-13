# Setup Guide

End-to-end setup for a working PR gate. Roughly 30-45 minutes for the first repo, 10-15 minutes for each additional one.

## Prerequisites

Before you start, confirm:

- [ ] Prisma Cloud tenant with Application Security module enabled
- [ ] Azure DevOps organization access with at least Project Administrator on the target project
- [ ] An ADO account or service account that can authenticate the integration (OAuth or PAT)
- [ ] At least one repo to onboard
- [ ] Buy-in from the repo owner — gating someone's branch without their knowledge is how you make enemies

## Phase 1: Onboard the repo to Prisma Cloud

### 1.1 Connect Azure DevOps as a provider

In Prisma Cloud:

1. **Settings → Providers → Repositories tab**
2. **Connect Provider → Azure Repos**
3. Choose **Single Organization** (most setups) or **Multiple Organizations** (only if your repos span ADO orgs)
4. Click **Authorize** — opens an ADO OAuth consent screen
5. Review the permissions requested. ADO's OAuth scopes are coarse-grained — Prisma asks for `Code (read and write)` because there's no `Code (read + comment)` option. The scope is broader than what's strictly needed but is standard for VCS integrations of this type.
6. Click **Accept**

> **Note on identity:** the OAuth grant is tied to the user account that authorized it. If that user leaves the org, the grant breaks. **Use a service account for production setups** (e.g., `svc-prismacloud@yourcompany.com`).

### 1.2 Select repositories

After authorization, choose **Choose from repository list** — don't pick "all existing" or "all existing and future." Explicit scope matters for licensing, ownership clarity, and avoiding the embarrassing "we accidentally onboarded another team's repos" situation.

Select the specific repos to onboard. You can add more later.

### 1.3 Verify the scan branch

After onboarding, each repo defaults to scanning its default branch. Verify this is what you want:

**Settings → Providers → Repositories → click the `•••` next to the repo → Set scanned branch**

Common gotchas:

- Repos where active development is on `develop` or `test` while `master`/`main` is stable — you may want to scan both
- Repos where the default branch is stale and not actually where PRs target
- Repos with multiple long-lived branches representing different environments

Match the scan branch to the branch your PRs target. If unsure, ask the repo owner.

### 1.4 Wait for the initial scan

Initial scans typically complete in 2-30 minutes depending on repo size. Check `Last Scan Date` on the Providers page. Findings will appear in:

- **Home → Projects → [repo]** — overview with finding counts
- **Home → Repositories** — the work view (note: indexing into this view can lag 30-60 min after scan completes)
- **Dashboards** — aggregate view across the tenant

## Phase 2: Configure enforcement rules

### 2.1 Find the Enforcement page

Prisma Cloud's enforcement config isn't where you'd expect. The path:

1. **Application Security → Home → Projects → [repo]**
2. Click the **hamburger menu (☰) icon in the top right** of the page
3. Select **Enforcement**

This opens the Enforcement dialog showing the main rule plus any exceptions.

### 2.2 Create an exception rule for your repo

Don't modify the main rule for a single-repo setup — it applies tenant-wide. Use an exception:

1. Click **Add Exception** (bottom right)
2. **Description:** clear name like `[repo-name] - Hard Fail Critical+`
3. **Repositories:** select your specific repo from the dropdown
4. **Labels:** leave blank (labels are optional metadata, not the scoping mechanism)
5. **Sliders:** set Hard Fail thresholds per category

Suggested starting thresholds for a new repo:

| Category | Hard Fail | Soft Fail | Comments Bot |
|----------|-----------|-----------|--------------|
| Vulnerabilities | Critical | High | Medium |
| Licenses | Critical | High | Medium |
| IaC | High | Medium | Low |
| Weaknesses | (disabled) | — | — |
| Secrets | Low | — | — |

Reasoning:

- Vulnerabilities at Critical-only avoids blocking on noisy transitive CVEs that may not have published fixes yet
- Secrets at Low because any secret is a problem regardless of severity score
- IaC at High because misconfigurations are usually findable and fixable with reasonable effort

You'll tighten these over time. Start permissive, demonstrate the gate works, ratchet down once triage capacity is proven.

6. **Save**

## Phase 3: Configure ADO branch policies

The exception rule alone does nothing. ADO has to enforce it.

### 3.1 Require pull requests

In ADO:

1. Repo → **Branches**
2. Find the protected branch → `•••` → **Branch policies**
3. Toggle **"Require a minimum number of reviewers"** to ON
4. Set minimum to **1** (or higher per your team's review standards)
5. Decide on **"Allow requestors to approve their own changes"** — context-dependent (see [Self-approval considerations](#33-self-approval-considerations))
6. Save

Without this, devs can push directly to the protected branch and bypass the gate entirely.

### 3.2 Add Prisma as a required status check

The second half of the gate. It can only be done **after Prisma has posted at least one status check on a PR for this repo** — otherwise the dropdown will be empty.

To bootstrap:

1. Have someone open a no-op test PR (README change, comment edit) targeting the protected branch
2. Wait 2-5 min for Prisma to scan and post a status check
3. Back in branch policies → **Status Checks → `+`**
4. Select `Prisma Cloud / Code analysis` from the dropdown
5. Set **Required**
6. Save

Now refresh the test PR. The merge button should reflect Prisma's status (and other required checks).

### 3.3 Self-approval considerations

The "Allow requestors to approve their own changes" setting depends on your team structure:

- **Large team with multiple reviewers:** turn OFF self-approval. Forces a real second pair of eyes.
- **Small team where the only reviewers are also the only committers:** allow it, but document the tradeoff. Otherwise reviews deadlock.
- **Mixed:** combine with **"Prohibit the most recent pusher from approving"** for a middle ground.

This isn't a Prisma question. It's a separation-of-duties question. Decide intentionally.

## Phase 4: Validate the gate works

Two tests prove the gate. Don't skip either.

### 4.1 Clean PR test (gate permits good code)

1. Create a branch off the protected branch
2. Make a trivial, harmless change (README tweak, comment, whitespace)
3. Open PR
4. Wait for Prisma scan
5. **Expected:** Prisma returns PASS, status check is green, merge button is enabled (pending other required checks like reviewer approval)

This proves the gate doesn't block normal work.

### 4.2 Dirty PR test (gate blocks bad code)

The cleanest reproducible test is a planted secret:

1. Create another branch
2. Add a new file (e.g., `secrets-test.txt`) with:
   ```
   AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
   AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
   ```
   > These are AWS's documented example credentials — intentionally non-functional, published in AWS's own documentation, and used industry-wide for testing secret scanners. Reference: AWS docs at `docs.aws.amazon.com/IAM/latest/UserGuide/security-creds.html`. They will not authenticate against any real AWS account.
3. Commit and open PR
4. Wait for Prisma scan
5. **Expected:** Prisma returns HARD_FAIL on Secrets, status check is red, merge button is disabled

This proves the gate actually gates.

### 4.3 What you should capture

Screenshots of both states for documentation:

- ADO PR overview showing the status check (success and failure states)
- ADO "View checks" detail panel
- Prisma's PR comment (scroll down on the PR)
- Prisma's VCS Pull Requests tab in the Projects view

## Phase 5: Handoff

Once the gate is working:

1. **Document the configuration**
   - Severity thresholds chosen
   - Repos in scope
   - Branch(es) being gated
   - Override/exception process and approvers
2. **Communicate to the affected team(s)**
   - What's gated, on which branches
   - What kinds of findings will block PRs
   - Who to contact for false positives or emergency overrides
   - Where to view findings (dashboard link)
3. **Set a follow-up checkpoint** at 30 days to review:
   - How many PRs hit the gate
   - How many of those were true positives vs false positives
   - Whether thresholds need adjusting

## Common setup issues

### Prisma doesn't post a status check on the test PR

Most likely cause: ADO service hooks didn't auto-create. Check:

1. ADO → **Project Settings → Service hooks**
2. Look for entries with publisher Azure Repos and consumer Prisma Cloud / Bridgecrew

If missing, the integration didn't fully wire up. Try removing and re-adding the repo in Prisma. If still failing, manually create a webhook pointing to the Prisma Cloud webhook URL for your tenant.

### "Prisma Cloud" doesn't appear in the Status Checks dropdown

Prisma must have posted at least one status to this repo before it shows up. Open a test PR first.

### Existing CVEs on main don't fail PRs

This is expected. PR scans evaluate the diff, not the full branch state. Existing findings need a separate triage workflow. See [enforcement rules guide](./03-enforcement-rules.md) for the full discussion.

### OAuth grant breaks after a user leaves

The grant was tied to a personal account. Re-authorize using a service account. See [PAT/OAuth rotation runbook](../runbooks/rotate-pat-or-oauth.md).
