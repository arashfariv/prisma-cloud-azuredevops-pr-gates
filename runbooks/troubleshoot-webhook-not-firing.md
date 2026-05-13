# Runbook: Troubleshoot Prisma webhook not firing on PRs

## Symptoms

One or more of:

- PR is opened but no Prisma status check appears
- Status check stays "pending" indefinitely
- Prisma's "VCS Pull Requests" tab in the project view stays empty after PRs are opened
- Branch scans run on schedule but PR-time scans don't fire
- Status check appears but with stale results from a previous scan

## Quick diagnosis flow

### Step 1: Confirm the integration itself is healthy

In Prisma Cloud:

1. **Settings → Providers → Repositories**
2. Find the affected repo
3. Check `Status` — is it `Connected`?
4. Check `Last Scan Date` — is it within the last 24 hours?

If `Status` is anything other than Connected, the integration auth is broken. Skip to [Authentication issues](#authentication-issues).

If `Last Scan Date` is older than 24 hours, scheduled scans aren't running either. This is a bigger problem than just webhooks — see [Authentication issues](#authentication-issues).

If both look healthy, continue.

### Step 2: Check ADO service hooks

In ADO:

1. **Project Settings → Service hooks**
2. Look for entries with publisher `Azure Repos` and consumer pointing to Prisma Cloud or Bridgecrew

Expected: at least one service hook for "Pull request created" and "Pull request updated" events targeting Prisma's webhook URL.

If missing entirely → see [Webhook missing](#webhook-missing) below.

If present but disabled → enable.

If present and enabled → check delivery history (click on a hook → History tab). Look for recent failed deliveries.

### Step 3: Test webhook delivery manually

If service hooks exist, trigger a delivery to verify:

1. In Service hooks, click on the hook
2. Click **Test** (or right-click → Test)
3. ADO sends a test payload to Prisma's webhook URL
4. Result: Success / Failure with response code

| Result | Meaning |
|--------|---------|
| 200 OK | Webhook is fine — issue is elsewhere |
| 401 / 403 | Prisma is rejecting auth — credential issue on Prisma side |
| 404 | Webhook URL is wrong or Prisma endpoint is down |
| 500 / 502 / 503 | Prisma's service is having an issue |
| Timeout | Network connectivity problem between ADO and Prisma |

### Step 4: Check Prisma's PR scan log

In Prisma Cloud:

**Application Security → Home → Projects → [repo] → VCS Pull Requests**

If a PR was opened recently and doesn't appear here, Prisma never received the webhook event. Confirms the issue is on the ADO → Prisma path.

If the PR appears but scan is stuck "in progress," the issue is in Prisma's scan execution, not the webhook.

## Common failure modes and fixes

### Webhook missing

Service hooks didn't auto-create when the repo was onboarded. This happens when the user who authorized the integration didn't have permission to create service hooks at the project level.

**Fix:**

1. Confirm the authorizing identity has Project Administrator (or higher) on the project
2. Re-authorize the integration with that identity
3. Service hooks should be created automatically

If re-authorization isn't an option:

**Manual webhook creation:**

1. ADO → Project Settings → Service hooks → **+ Create subscription**
2. Service: **Web Hooks**
3. Event: **Pull request created** (and repeat for **Pull request updated**)
4. Filter: select your repo (or leave for all repos)
5. URL: get the Prisma webhook URL from Prisma Cloud → Settings → Providers → repo settings (varies by Prisma version)
6. Test the new hook

### Authentication issues

Status shows broken or scheduled scans aren't running.

**Fix path 1: PAT expired**
- See [PAT/OAuth rotation runbook](./rotate-pat-or-oauth.md)

**Fix path 2: OAuth grant revoked**
- The user who authorized may have left, or their account was disabled
- See OAuth path in [PAT/OAuth rotation runbook](./rotate-pat-or-oauth.md)

**Fix path 3: Service account locked or password changed**
- ADO service account auth can be revoked through MFA / conditional access policies
- Verify the service account can still log into ADO independently

### Webhook fires but Prisma doesn't post status

ADO is sending events, Prisma is receiving them, but status checks aren't appearing on PRs.

Possible causes:

**Cause 1: Insufficient OAuth scopes**

Prisma needs `Code (Read & Write)` to post PR statuses. If it only has Read, scans run but no status is posted.

Fix: re-authorize with the correct scopes.

**Cause 2: Status check name mismatch in branch policy**

If the branch policy is configured to require a status check named differently from what Prisma posts, the check appears but as "unknown" or doesn't trigger merge blocking.

Verify the policy's status check name matches `Prisma Cloud / Code analysis` exactly (or whatever your tenant's Prisma uses — varies slightly by version).

**Cause 3: PR scan disabled in enforcement rule**

If the enforcement rule for this repo has Hard/Soft Fail set to Off across categories, Prisma scans but doesn't return a meaningful status.

Verify the exception rule for this repo has appropriate thresholds set.

### Stale status checks (PR shows old scan results)

The PR was scanned but the status reflects a previous version of the diff.

**Cause 1: Webhook for "Pull request updated" missing**

The "PR created" webhook fires once. New commits to the PR branch should trigger a re-scan via the "PR updated" webhook. If only the "created" hook exists, the scan won't refresh.

Fix: add a service hook for "Pull request updated" event.

**Cause 2: Scan caching**

Some Prisma configurations cache scan results to avoid re-scanning identical content. Push an empty commit to force a re-scan:

```bash
git commit --allow-empty -m "Force Prisma re-scan"
git push
```

### Scans run but findings are stale or wrong

Different problem entirely — scans are completing but the findings don't reflect current code.

**Possible causes:**

- Prisma's policy database hasn't updated (some CVEs added post-scan won't appear until next scan)
- Repo was scanned at a previous commit (force re-scan as above)
- File scanner doesn't support a particular language/framework you've added recently

For these, contact Palo Alto support.

## Escalation

If you've worked through this runbook and the issue isn't resolved:

### Internal escalation

- Confirm the issue is reproducible (multiple PRs, multiple repos, or just one?)
- Gather diagnostic data:
  - Repo name and Prisma integration ID
  - PR number where the issue is observed
  - Timestamps of PR open vs expected scan time
  - Service hook delivery history screenshots
  - Any error messages from Prisma Cloud
- Open ticket with Palo Alto support with the above

### External escalation (Palo Alto support)

Tier 1 support typically asks for:
- Tenant name
- Integration name
- Affected repos
- Reproduction steps
- Timestamps in UTC

Have these ready. Escalation can be slow if you don't have them upfront.

## Preventive monitoring

To catch webhook issues before users complain:

1. **Periodic test PR:** schedule a job that opens a no-op test PR weekly and verifies Prisma posts a status. Alerting on absence catches integration breaks.

2. **Service hook delivery monitoring:** ADO Service Hooks page shows delivery success rate. Add to your monitoring dashboard.

3. **Prisma scan freshness check:** alert if `Last Scan Date` on any onboarded repo is older than 48 hours. Indicates the integration is broken even if no PRs have been opened to surface the issue.

4. **Owner feedback loop:** check in with repo owners monthly. They'll notice gate weirdness before automated monitoring does.
