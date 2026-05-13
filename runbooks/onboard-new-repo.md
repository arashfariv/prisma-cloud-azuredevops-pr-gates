# Runbook: Onboard a new repo to Prisma Cloud PR gating

## When to use this runbook

A new repo needs to be added to Prisma Cloud scanning with PR enforcement.

## Prerequisites

- [ ] Repo exists in Azure DevOps
- [ ] Repo owner is aware and has agreed to gating
- [ ] Severity threshold pattern decided (see [enforcement rules](../docs/03-enforcement-rules.md))
- [ ] Time budget: ~20-30 min

## Steps

### 1. Confirm scope with the repo owner (5 min)

Quick conversation or message:

- Which branch should be gated? (Default branch is usually right — verify, don't assume)
- Which severity threshold pattern fits this repo? (Conservative / Standard / Strict)
- Who's the triage contact for findings?
- Any known existing issues to flag for suppression at onboarding?

Don't skip this. Onboarding without owner buy-in causes more problems than it solves.

### 2. Onboard to Prisma Cloud (5 min)

In Prisma Cloud:

1. **Settings → Providers → Repositories**
2. Click `•••` next to your existing Azure Repos integration → **Select Repositories**
3. Search for the new repo → check it → **Save**
4. Confirm the repo appears in the Repositories list with **Status: Connected**
5. Note the timestamp — used to measure scan time later

If the repo doesn't appear in the search:

- Verify your OAuth/PAT has access to the project containing the repo
- May need to expand the integration's permission scope
- Some repos in different projects may require a separate integration

### 3. Set the scan branch (1 min)

If the repo's default branch is not the one you want scanned:

1. Click `•••` on the repo row → **Set scanned branch**
2. Select the correct branch
3. Save

This triggers a fresh scan on the selected branch.

### 4. Wait for initial scan (5-30 min)

Scan time depends on repo size:

- Small (~50 files): 2-5 min
- Medium (~500 files): 10-15 min
- Large (5000+ files or sprawling history): 30+ min

Check `Last Scan Date` on the Providers page. Findings appear in the dashboard near-immediately after scan completes; the Home → Repositories view may lag 30-60 min.

### 5. Review baseline findings (5-10 min)

In **Home → Projects → [your repo] → Overview**:

- Note total finding count
- Note severity distribution
- Click into top findings to understand what's there
- Identify any obvious false positives or accepted-risk findings to suppress at onboarding

If findings volume is high (>50), set expectations with the owner: triage is going to take time, and the gate doesn't auto-fix existing issues.

### 6. Configure enforcement exception rule (5 min)

In Prisma Cloud:

1. **Application Security → Home → Projects → [your repo]**
2. Click hamburger (☰) → **Enforcement**
3. **Add Exception**
4. Fill in:
   - **Description:** `[repo-name] - [pattern name]` (e.g., `payments-api - Standard Enforcement`)
   - **Repositories:** select your repo
   - **Sliders:** apply chosen pattern from [enforcement rules](../docs/03-enforcement-rules.md)
5. **Save**

### 7. Bootstrap the ADO status check (5 min)

ADO needs to see at least one Prisma status post before you can mark it Required.

Have the repo owner (or you, if you have push access) open a no-op test PR:

1. Create branch `test/prisma-bootstrap` off the protected branch
2. Add a comment to README or any minor change
3. Commit, open PR targeting the protected branch
4. Wait 2-5 min — Prisma posts a status check + comment

### 8. Configure ADO branch policy (5 min)

In ADO:

1. Navigate to repo → **Branches** → find protected branch → `•••` → **Branch policies**
2. **Require a minimum number of reviewers:** ON, minimum 1 (or higher per team)
3. **Status Checks → +** — select `Prisma Cloud / Code analysis` → **Required** → save
4. Verify the test PR now reflects the required status

For larger rollouts, use [`Add-PrismaGate.ps1`](../tools/Add-PrismaGate.ps1) instead of clicking through the UI.

### 9. Validate the gate (10 min)

Two test PRs prove the gate works:

**Clean PR test:**
- Use the same `test/prisma-bootstrap` PR or open a new one with a trivial change
- Expected: Prisma returns PASS, merge button enabled (pending reviewer approval)

**Dirty PR test:**
- New branch, add a file with the test secret:
  ```
  AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
  AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  ```
  > AWS's documented example credentials — non-functional, published by AWS, will not authenticate. Used industry-wide as canonical test values for secret scanners.
- Expected: Prisma returns HARD_FAIL on Secrets, merge button disabled

Capture screenshots of both states for documentation.

### 10. Clean up test artifacts (2 min)

- Delete the test branches
- Close test PRs (don't merge the dirty PR)
- Verify no test secrets remain in any branch (a `git log` on the test branch should show only the test commits)

### 11. Update tracking (3 min)

Record the onboarding in your change log / tracker:

- Repo name
- Date onboarded
- Branch gated
- Threshold pattern applied
- Owner contact
- Baseline finding count
- Any suppressions applied at onboarding (with justification)

### 12. Notify the owner (2 min)

Closing communication:

```
Onboarding complete for [repo].

Configuration:
- Scanning: [branch] branch on every PR
- Threshold: [pattern name] - blocks on [criteria]
- Existing findings: [count] - tracked in dashboard, don't block PRs

Validated:
- Clean PR passes ✓
- Test secret PR blocks ✓

To view findings: [Prisma Cloud link to repo's project page]
For overrides or false positives: [your contact info / process link]

Anything looks off, let me know.
```

## Rollback

If the gate is causing problems and needs to be removed:

1. **ADO:** Branches → protected branch → Branch policies → Status Checks → remove Prisma → save
2. **Prisma:** Enforcement page → delete the exception rule for this repo
3. Optionally remove the repo from Prisma scanning entirely (Providers → repo → Delete Repository)

The repo can be re-onboarded later. No data loss in the rollback path.

## Common issues during onboarding

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Repo doesn't appear in Prisma's selection list | OAuth scope doesn't cover the repo's project | Re-authorize integration with broader scope |
| Initial scan stuck > 1 hour | Repo too large for default scan timeout | Contact Palo Alto support, may need scan config adjustment |
| Prisma never posts status on test PR | Service hooks not auto-created | Check Project Settings → Service hooks; manually create if missing |
| Status check name not in dropdown | No PR has been scanned yet | Open a test PR first, wait for scan, then add as required |
| Gate too noisy on day 1 | Threshold pattern too strict | Loosen threshold (use Conservative pattern), tighten over time |

## Time estimate summary

| Step | Time |
|------|------|
| Owner alignment | 5 min |
| Onboard to Prisma | 5 min |
| Wait for initial scan | 5-30 min (parallel) |
| Review baseline | 5-10 min |
| Configure exception rule | 5 min |
| Bootstrap status check | 5 min (parallel with scan wait) |
| Configure branch policy | 5 min |
| Validate gate | 10 min |
| Cleanup + docs + comms | 5 min |
| **Total active time** | **~45 min** |
