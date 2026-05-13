# Runbook: Handle a PR gate bypass request

## When to use this runbook

A developer needs to merge a PR that the Prisma gate is blocking. They've reached out asking for an override.

## Decision framework

Not all bypass requests are equal. Different reasons need different responses.

### Category 1: Emergency hotfix

**Scenario:** Production is down or impaired, fix needs to ship now, gate is blocking.

**Response:** Approve the bypass. Document for post-incident review.

**Justification accepted:** "Customer-facing outage, fix has been validated, security finding is unrelated to the issue and will be addressed in a follow-up PR."

**Required:**
- Incident ticket reference
- Brief description of what's being shipped and why
- Commitment to address the security finding within X days (default: 7)

### Category 2: False positive

**Scenario:** The finding doesn't apply to your code's actual usage. Common with SCA findings on transitive dependencies that aren't actually called.

**Response:** Don't bypass. Suppress the finding instead.

**Why:** Bypassing makes the finding fire again on the next PR. Suppressing handles it permanently.

**Process:**
1. Verify it's actually a false positive (don't take the requester's word)
2. In Prisma Cloud, mark the finding as suppressed with reason "False Positive — [explanation]"
3. Tell the requester: "Suppressed; re-run the scan and your PR should pass"

### Category 3: Accepted risk

**Scenario:** Finding is real but the team has decided to accept the risk for documented reasons.

**Response:** Bypass requires sign-off, then suppress with justification.

**Required:**
- Risk acceptance approved by the appropriate authority (security lead, repo owner, or higher depending on severity)
- Written justification (compensating controls, business reason, planned future remediation)
- Review date (when will this be revisited?)

**Process:**
1. Get written sign-off (email or ticket comment is fine — needs to be auditable)
2. Suppress finding in Prisma Cloud with the justification text
3. Set a review date in your tracking system

### Category 4: Fix is too disruptive

**Scenario:** The fix exists but applying it would require significant refactoring, breaking changes, or work the team doesn't have capacity for right now.

**Response:** Don't bypass. Defer instead.

**Process:**
1. Convert the finding into a tracked issue (work item, Jira, etc.)
2. Suppress the finding with note: "Deferred to [issue link] for remediation"
3. Set a target date and review reminder

The finding doesn't disappear — it moves to a planned remediation queue.

### Category 5: "I don't want to deal with this"

**Scenario:** Developer is annoyed, wants to merge, doesn't want to engage with the finding.

**Response:** Decline the bypass. Engage on the substance of the finding.

This category is real and common. Your job is to engage, not to rubber-stamp:

- "Walk me through what this finding is about?"
- "What's blocking you from fixing it in this PR?"
- "Is there a different solution we could try?"

If after good-faith engagement the finding really is wrong, blocked by external factors, or genuinely accepted risk — handle as Categories 1-4. If the developer just wants the gate to go away, hold the line.

## The bypass mechanics

If you've decided to grant a bypass, here's how it actually works in ADO + Prisma:

### Option A: One-time PR completion (preferred)

ADO branch policies have an **"Allow completion even if some reviewers vote 'Waiting' or 'Reject'"** setting, plus the **"Bypass policies when completing pull requests"** permission.

If you have the permission:

1. Open the PR
2. Click the dropdown next to the merge button → **Set auto-complete** or similar
3. Confirm the override
4. PR merges despite failed checks

This generates an audit log entry. Use this rather than disabling the policy.

### Option B: Suppress the finding (for false positive / accepted risk)

1. In Prisma Cloud, navigate to the finding
2. Click the suppress option (varies by Prisma version — usually a `•••` menu on the finding row)
3. Provide justification text
4. Save

The next PR scan will not flag the suppressed finding. The bypass becomes permanent rather than per-PR.

### Option C: Adjust the threshold (last resort)

If many PRs are hitting the gate on the same category, the threshold may be too strict. Consider:

1. Review enforcement rule for the affected repo
2. If the finding pattern is genuinely too noisy at the current threshold, loosen it (e.g., Hard Fail at High → Critical)
3. Document the change with reason

Don't do this casually — it weakens enforcement for all future PRs, not just the one in question.

## What to avoid

### Don't disable the policy temporarily

"I'll just turn off the required check for 5 minutes." Don't. You'll forget to turn it back on, or someone else will need it off and you'll never get back to enforced state.

### Don't bypass without an audit trail

Every bypass should produce an artifact:
- Incident ticket
- Email approval
- Comment in the PR explaining why
- Suppression record in Prisma

If a bypass happens and there's no record, that's an audit finding waiting to happen.

### Don't bypass without engaging on the finding

"I'll just bypass this" without understanding what was flagged means you don't know what risk you're accepting. At minimum, read the finding and confirm you understand what it's saying.

### Don't let bypass become routine

If 20% of PRs need bypasses, the gate is misconfigured. Loosen thresholds, fix false positive sources, or reconsider the rollout plan. Bypass should be the exception, not the workflow.

## Tracking bypass requests

Keep a log of all bypasses. At minimum:

| Date | PR | Repo | Requester | Reason category | Approver | Resolution |
|------|----|----|-----------|-----------------|----------|------------|

Review monthly:

- How many bypasses?
- What categories?
- Are the same repos / teams asking repeatedly?
- Are the same finding types triggering bypasses repeatedly?

The log is feedback. Use it to tune thresholds, retire false-positive prone policies, or escalate problem patterns.

## Communication template — granting a bypass

```
Approved bypass for PR #[number] on [repo].

Justification: [emergency hotfix / false positive / accepted risk / deferred]
Reference: [incident ticket / approval email / suppression record]

Follow-up actions:
- [ ] [If hotfix: address the security finding in a follow-up PR by date]
- [ ] [If accepted risk: review by date]
- [ ] [If false positive: suppression already in place]

Bypass logged in [tracking system].
```

## Communication template — declining a bypass

```
I can't approve the bypass on PR #[number] as currently described.

The finding flagged is [type], severity [level]. [Brief description of why it matters.]

Options:
1. Fix the finding in this PR
2. If you believe it's a false positive, here's how to verify: [steps]
3. If you need to defer, open a tracked issue with target date and I can suppress with justification

Happy to talk through the finding if it would help. [Link to finding details]
```
