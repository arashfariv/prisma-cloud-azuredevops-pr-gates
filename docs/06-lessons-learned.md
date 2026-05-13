# Lessons Learned

Things that aren't in the official docs, or are buried so deep they may as well not be. Read this before you commit to a rollout.

## Discovery

### The Enforcement page is hidden behind a hamburger menu

The PR enforcement configuration isn't under Settings, isn't under Application Security tenant config, and isn't accessible from the Providers page. It's behind the **hamburger menu (☰)** on a project's page.

Path: Application Security → Home → Projects → [your repo] → hamburger icon top right → Enforcement.

If you're hunting for "where do I configure PR gates," that's where it is. This took me real time to find. Documenting so you don't repeat it.

### Repository labels aren't the scoping mechanism

The Enforcement dialog has a "Labels (Optional)" field that suggests labels are how you scope rules to repos. They're not. The actual scoping is via the **Repositories** field on Exception rules.

Labels are optional metadata. Use them or don't. Don't waste time trying to figure out how to "tag a repo with a label" — it's not a feature you need.

### "VCS Pull Requests" tab shows scan history per repo

Buried under the project view. Useful when validating that scans actually fired on a PR. If empty after a PR is opened, your webhook isn't wired up.

## Authentication and identity

### OAuth grants tie to a personal account by default

When you authorize the Prisma Cloud OAuth app in Azure DevOps, the grant is bound to whatever ADO identity is logged in at that moment. If that's a personal account, the grant breaks when that person leaves the org.

Use a service account from the start. Saves a re-onboarding later.

### ADO OAuth scopes are coarser than they need to be

Prisma Cloud requests `Code (read and write)`. There's no `Code (read + comment)` scope in ADO. The "write" capability is needed to post PR comments and create the "fix" PRs that Prisma can suggest.

This sometimes raises eyebrows during security review. The response: ADO's scope model is coarse, the alternative is no integration, and the scope is consistent with similar VCS-integrated security tools (GitHub Advanced Security, Snyk, etc.).

### PATs expire and silently break scanning

If you used a PAT instead of OAuth, set a calendar reminder 30 days before expiry. PATs cap at 1 year in ADO. When they expire, scans just stop. No alert, no banner, just silence.

OAuth doesn't have this problem (no expiration), which is part of why I prefer it.

## Webhooks

### Service hooks may not auto-create

The Prisma Cloud integration is supposed to create ADO service hooks (webhooks) automatically during onboarding. Sometimes it doesn't, depending on the permissions of the user who authorized.

Symptoms: scans run on schedule but PRs don't trigger immediate scans, "VCS Pull Requests" tab stays empty.

Fix: Project Settings → Service hooks. If no Prisma-related hooks, manually create one or re-authorize with a higher-permission account.

### Webhook delivery isn't always instant

When everything's wired up correctly, expect 30 seconds to 2 minutes from PR open to Prisma starting the scan. Then another 1-3 minutes for the scan to complete. Total: typically 2-5 minutes from PR open to status check posted.

If it's longer than 5 min, something's wrong. Check service hooks first.

## PR scan behavior

### Diff-only is default and not configurable

I went into this thinking "delta-only" was a toggle that would need configuring. It isn't. Prisma's PR scans evaluate the **diff**, not the full branch. Existing branch findings don't fail every PR.

This caught me by surprise during initial testing. Spent time trying to get existing CVEs to trigger on a clean PR — they wouldn't, by design.

It's actually the right behavior. Don't fight it. Use suppressions for findings you want acknowledged but not enforced.

### "Touching the file with the finding" doesn't necessarily re-trigger it

Logical assumption: if you edit a `.csproj` file (or `package.json`, or any dependency manifest) that has a vulnerable dependency declaration, the PR scan should flag the existing CVE because the file is in the diff.

Reality: it doesn't (in the configurations I tested). Prisma seems to evaluate finding presence at the line level, not the file level. Edit a comment in the same file and the existing finding stays as branch-level baseline, not PR-introduced.

This means the gate genuinely only fires on PR-introduced new findings, not on "touched a file that has findings." Useful to know for demos — you can't reliably demonstrate the gate by touching files. You have to introduce a new finding.

### Best demo finding is a planted secret

For demonstrations, the most reliable "this PR will be blocked" change is adding a new file with a fake AWS key:

```
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

> These values are AWS's documented example credentials — intentionally non-functional, published by AWS for documentation and testing purposes. They will not authenticate against any real AWS account. Used industry-wide as the canonical test values for secret scanners.

Prisma's secrets scanner will flag them every time. Cleanest demo path.

## ADO branch policies

### "Required reviewers" off by default on most repos

Don't assume your protected branches are protected. New repos in ADO accept direct pushes to main unless someone explicitly turned on the reviewer requirement.

This is the single biggest gap I found during the work. Auditing existing repos for this revealed a meaningful percentage with policies missing.

If you onboard repos that have permissive branch policies, the Prisma gate is decoration. Audit and fix branch policies as part of the rollout, not as an afterthought.

### Status checks have to exist before they can be made required

Adding "Prisma Cloud" as a Required status check requires that Prisma has posted at least one status to the repo. Otherwise the dropdown is empty.

Bootstrap order: open a no-op test PR → wait for Prisma to post → go add the required check → repush to re-trigger → done.

### "Allow requestors to approve their own changes" is on by default

For small teams where reviewers and committers overlap, this is sometimes correct. For larger teams, it should be off.

Not a Prisma thing — separate ADO policy. But it affects whether your gate has real review behind it.

### Auto-included reviewers ≠ required PRs

A common misconfiguration: auto-include reviewers from a security group on PRs, but don't require PRs in the first place. Result: the auto-include rule fires only when someone happens to open a PR. Direct pushes bypass entirely.

Audit for this. The presence of auto-include reviewers can be misleading evidence of "we have review."

## Performance and scale

### Initial scans are slow on large repos

A small .NET API took 2 minutes. A large monorepo can take 30+ minutes. Plan onboarding accordingly — don't expect findings instantly on big repos.

### Indexing into the Home → Repositories view lags

Scans complete on the Providers page (you see a Last Scan Date timestamp) but findings can take 30-60 minutes to appear in the Home → Repositories work view.

If findings are missing in that view but exist on the Dashboard or in Projects → Overview, indexing hasn't caught up. Wait, don't troubleshoot.

### Scheduled scans run roughly daily

In addition to PR scans, Prisma re-scans branches on a schedule (about once per day in my observation). Useful for catching:

- Findings that emerged after a merge (CVE published later)
- Direct pushes by users with bypass permissions
- Re-evaluation when policies change

Treat scheduled scans as the safety net, not the primary gate.

## Operational reality

### Existing findings are a separate problem from PR gating

The gate catches new findings. Existing findings need their own workflow — fix, suppress, or accept.

If you onboard a repo with 200 existing findings, the gate doesn't make those go away. They sit in the dashboard. The team has to triage them as a separate exercise, prioritized against other engineering work.

Don't promise leadership "we're now secure on this repo because we turned on the gate." The gate stops new badness; the dashboard tracks existing debt.

### Triage capacity is the real bottleneck

Scanning is the easy part. Triaging findings — figuring out which are real, which are false positives, which need fixing now vs later — takes engineering time.

If you onboard 10 repos and find 800 findings, but no one is allocated to triage them, the findings just sit there. The gate works, the dashboard is full, nobody's safer.

Plan for triage capacity before you scale onboarding. Otherwise you're building a beautiful tool for a problem nobody's empowered to solve.

### Bypass requests will happen

No matter how well you set thresholds, someone will hit the gate during an emergency hotfix. Decide the override process before you turn on enforcement:

- Who can grant bypass?
- What's required to request it (work item, sign-off, post-incident review)?
- Where's the audit trail?

Without this, the first time someone needs a bypass, you'll improvise. Improvising security overrides under deadline pressure is how compensating controls get bypassed permanently.

## Reporting and visibility

### The Dashboard view aggregates faster than other views

If you want to confirm Prisma is finding things, the **Dashboards** view updates almost immediately after scans. Other views (Repositories, Projects) can lag.

For "is the scanner working?" check Dashboards first.

### "Insecure Repositories" list shows tenant-wide findings

When you log in and see a "Top Insecure Repositories" list, it's showing repos across the whole tenant — including ones you didn't onboard, ones that other teams onboarded, etc.

If you see repos in that list you don't recognize, that's not a security incident — it's evidence that other people are using the same tenant. Coordinate with whoever else is in there.

## Automating branch policies via the ADO REST API

The PowerShell tool in `tools/Add-PrismaGate.ps1` automates the ADO side of the gate. Building it surfaced a handful of API quirks that aren't documented anywhere I could find. Documenting them here so the next person doesn't have to rediscover.

### Quirk 1: The policy API returns inherited and wildcard policies, not just exact-scope

Querying `/policy/configurations?repositoryId=X&refName=refs/heads/main` returns *every policy that could apply* to that ref — including project-wide defaults, wildcard patterns, repo-wide settings, and inherited rules. A query on one repo's main branch can return 100-150 policies.

To check if a policy is *actually configured at the branch level*, filter for:

- `repositoryId == target`
- `refName == "refs/heads/$Branch"`
- `matchKind == 'Exact'`

Without this filter, idempotency checks falsely identify branch-exact policies as "already exists" when they're actually inherited or wildcard-applied. The script will skip work that needs to be done.

### Quirk 2: Single-element scope arrays get unwrapped by ConvertTo-Json

The `scope` field of a policy body must be a JSON array, even with only one entry:

```json
"scope": [
  {
    "repositoryId": "...",
    "refName": "refs/heads/main",
    "matchKind": "Exact"
  }
]
```

In PowerShell, you'd think `scope = @($hash)` would do it. It doesn't. `ConvertTo-Json` silently unwraps single-element arrays in nested properties, producing `"scope": { ... }` instead of `"scope": [ { ... } ]`. ADO returns a 400 with `Expected '['. Path: 'scope'`.

The fix: use the unary comma operator at the assignment point.

```powershell
scope = ,(New-BranchScope -RepoId $RepoId)
```

The comma operator unambiguously creates an array that survives serialization.

### Quirk 3: requiredReviewerIds wants GUIDs, not identity descriptors

The required-reviewer policy is one of the few that uses GUIDs:

```json
"requiredReviewerIds": ["abc12345-de67-89ab-cdef-1234567890ab"]
```

Not the legacy descriptor (`Microsoft.TeamFoundation.Identity;S-1-9-...`), not the Graph descriptor (`vssgp.Uy0xLT...`). The GUID specifically.

Resolve the GUID via the identities endpoint:

```
GET /_apis/identities?subjectDescriptors={url-encoded-graph-descriptor}
```

Take the `.id` field from the response. That's your GUID.

### Quirk 4: ADO Graph API requires paging for non-trivial tenants

Large tenants have more than 500 groups. The default response is a single page. Continuation tokens come back in response headers (`X-MS-ContinuationToken`), not in the body. You need `Invoke-WebRequest` (not `Invoke-RestMethod`) to access response headers.

```powershell
$response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing
$continuationToken = $response.Headers['X-MS-ContinuationToken']
if ($continuationToken -is [array]) { $continuationToken = $continuationToken[0] }
```

### Quirk 5: PowerShell's `-like` treats `[` and `]` as character class brackets

Trying to filter groups whose principalName starts with `[Project Name]`:

```powershell
$_.principalName -like "[Project Name]*"
```

This silently matches nothing, because PowerShell interprets `[Project Name]` as a character class meaning "one character from this set" — not the literal bracketed string.

Use `.Contains()` or `.StartsWith()` for literal string matching:

```powershell
$_.principalName.Contains("[Project Name]")
```

### Quirk 6: $input is a reserved variable

Using `$input = Read-Host ...` in a function silently fails because `$input` is a PowerShell automatic variable that gets clobbered by pipeline handling. Use any other name (`$userInput`, `$choice`, etc.).

### Quirk 7: Add-Content respects -WhatIf

Logging functions that use `Add-Content` are blocked by `-WhatIf` because `Add-Content` supports `ShouldProcess`. Dry runs end up with no log file written, just console output.

To make logs always write regardless of WhatIf state:

```powershell
Add-Content -Path $logFile -Value $line -WhatIf:$false -Confirm:$false
```

### Quirk 8: PAT scope requirements are stricter than they seem

For the full set of policy operations, the PAT needs:

- `Code (Read & Write)` — for policy CRUD
- `Project and Team (Read & Write)` — for repo lookup
- `Identity (Read)` — for converting Graph descriptors to GUIDs
- `Graph (Read)` — for listing groups
- `Member Entitlement Management (Read)` — for resolving user/group memberships

The script will fail with confusing error messages if any of these is missing. The 400 from the policy POST won't tell you "your PAT needs more scope" — it'll tell you something like "Group lookup returned empty" or "Cannot resolve identity."

### Quirk 9: ADO error responses contain useful detail in different fields by PowerShell version

`Invoke-RestMethod` throws on 4xx/5xx. The actual error message from ADO is in:

- **PowerShell 7+**: `$_.ErrorDetails.Message`
- **Windows PowerShell 5.x**: `$_.Exception.Response.GetResponseStream()`

A robust error-extraction function needs to check both locations. The script's `Invoke-PolicyPost` helper handles this.

---

## Things I'd do differently next time

1. **Audit branch policies first.** Before configuring Prisma at all, spend a day inventorying which protected branches actually require reviewers, which require status checks, which allow direct push. Knowing the governance gaps shapes the rollout.

2. **Set up a service account from day one.** Don't authorize OAuth with a personal account "just to get the POC running." Service account is 30 minutes upfront and saves a re-onboarding later.

3. **Document the override process before turning on enforcement.** Write the runbook for "developer hits the gate during emergency" before they hit it. This forces good decisions when nobody's panicking.

4. **Start with warn-only longer than feels necessary.** 4 weeks of warn-only is better than 1 week. The data is more reliable, the team has more buy-in, the false positive rate is better understood.

5. **Pick one finding per category to deeply understand before scaling.** Reading every finding is overwhelming. But picking one Vulnerability, one Secret, one IaC misconfiguration and tracing them end-to-end (file, fix, suppression, dashboard appearance, PR comment) builds enough mental model to scale up confidently.

6. **Build the automation tool first, then onboard repos.** I did this in reverse — onboarded several repos manually, then built the tool. Doing it the other way around would have saved roughly two days of UI clicking and produced more consistent configuration across the early batch.
