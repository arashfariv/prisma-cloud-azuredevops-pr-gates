# Add-PrismaGate.ps1

PowerShell tool that configures Azure DevOps branch policies for Prisma Cloud PR gating. Designed to apply a consistent set of four policies across one or many repos, idempotently.

## What it does

For a given repo + branch, applies all four policies needed for a working gate:

1. **Require a minimum number of reviewers** — forces PRs, prevents direct push
2. **Require comment resolution** — PRs can't merge with unresolved comments
3. **Require an auto-included reviewer group** — e.g., Code Review Approvers
4. **Require Prisma Cloud status check** — the security gate itself

All four policies coordinated. All four reach the same end state. Re-running the script on a repo where some policies are already configured just fills in the missing ones.

## Why this exists

Configuring four coordinated branch policies via the UI is about 15 clicks per repo. Across 50 repos that's a tedious afternoon with high error rate. The script reduces it to one command. More importantly, it reduces it to one command **that produces consistent configuration every time** — same severity defaults, same group identity, same scope semantics.

The script also encodes a handful of ADO REST API quirks that aren't documented (see [the lessons-learned doc](../docs/06-lessons-learned.md) for details). Anyone trying to script this from scratch will hit those same quirks; this script is one solution that's been validated against a real ADO tenant.

## Three modes

### Interactive mode (recommended for ad-hoc runs)

```powershell
$env:ADO_PAT = "your-pat-here"
.\Add-PrismaGate.ps1 -Interactive
```

The script prompts for:

- Organization (defaults to `your-org` — override at the prompt)
- Project (numbered picker, discovered from ADO)
- Repos (multi-select via `Out-GridView`, or console fallback)
- Branch (auto-detected from each repo's default; override per repo)
- Reviewer group (regex-matched from project groups, falls back to full list)
- Confirmation summary + WhatIf/Live/Cancel

### Single-repo mode (parameterized)

```powershell
.\Add-PrismaGate.ps1 `
    -Organization "your-org" `
    -Project "Your Project Name" `
    -RepoName "sample-api-repo" `
    -Branch "main" `
    -ReviewerGroup "[Your Project Name]\Code Review Approvers" `
    -WhatIf
```

Drop `-WhatIf` to apply for real.

### Bulk mode (from a file)

```powershell
.\Add-PrismaGate.ps1 `
    -Organization "your-org" `
    -Project "Your Project Name" `
    -RepoList ".\repos.txt" `
    -Branch "main" `
    -ReviewerGroup "[Your Project Name]\Code Review Approvers" `
    -WhatIf
```

`repos.txt` is one repo name per line. Comments with `#`. Single branch applied to all repos in the list.

## Prerequisites

- Prisma Cloud tenant with Application Security
- Each target repo onboarded to Prisma Cloud
- At least one PR has been scanned by Prisma so the status check name exists in ADO (otherwise the policy will be created but no PR will ever satisfy it)
- ADO PAT with scopes:
  - **Code (Read & Write)**
  - **Project and Team (Read & Write)**
  - **Identity (Read)** — required for group lookups
  - **Graph (Read)** — required for group lookups
  - **Member Entitlement Management (Read)**
- Project Administrator on the target ADO project

## Run safety

The script supports PowerShell's standard `-WhatIf` for dry runs. **Always run with `-WhatIf` first** before applying to a new repo. The dry run shows the planned policy actions without making any API writes.

The script is also idempotent:
- Existing policies of the same type on the same branch are detected and skipped
- Re-running is safe; the script won't create duplicate policies
- A partial run can be resumed by re-running — it'll skip what already exists

## What it doesn't do

- **Doesn't onboard repos to Prisma Cloud.** That's a different API and a separate workflow. Onboard first, then gate.
- **Doesn't validate that Prisma has posted a status check.** It just configures ADO to require one. If Prisma never scans the repo, the gate will block every PR forever waiting for a check that never arrives.
- **Doesn't roll back.** No `Remove-PrismaGate.ps1` is included. If you need to remove policies, do it via the ADO UI or write the inverse via the same REST API.
- **Doesn't handle ADO Server (on-prem).** Cloud only (`dev.azure.com`).
- **Doesn't support different branches per repo in bulk file mode.** The interactive mode handles per-repo branches. Bulk file mode applies the same branch to all repos.

## ADO policy type IDs

For reference, these are the ADO branch policy type IDs the script uses. They're constant across all ADO orgs:

| Policy | Type ID |
|--------|---------|
| Minimum reviewers | `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` |
| Build validation | `0609b952-1397-4640-95ec-e00a01b2c241` |
| Status check | `cbdc66da-9728-4af8-aada-9a5a32e4a226` |
| Comment resolution | `c6a1889d-b943-4856-b76f-9e46bb6b0df2` |
| Required reviewer (auto-include) | `fd2167ab-b0be-447a-8ec8-39368250530e` |

## Design notes

### Why interactive mode uses Out-GridView for repo selection

`Out-GridView` provides a real Windows GUI window with checkboxes and search-as-you-type. For projects with hundreds of repos, this is dramatically better than a numbered console list. The script falls back to a console picker (`1,3,5-8` syntax) if `Out-GridView` isn't available.

### Why scope checks are exact-match only

ADO's policy API returns *all policies that could apply* to a branch — including project-wide defaults, wildcard patterns, and inherited rules. A query for `refs/heads/main` on one repo can return 100+ policies, most of which aren't actually configured at the branch level. The script filters these to only those scoped exactly to the target repo + branch with `matchKind: Exact`. Without this, the idempotency check incorrectly thinks "policy exists" and skips repos that need configuration.

### Why required reviewers needs a GUID

ADO's required-reviewer policy specifically wants the identity GUID in `requiredReviewerIds`. Other identity formats (Graph descriptor `vssgp.Uy0x...`, legacy descriptor `Microsoft.TeamFoundation.Identity;S-1-9-...`) won't work. The script resolves a group's principalName to the GUID via the identities endpoint.

### Why the scope field uses the unary comma

PowerShell's `ConvertTo-Json` silently unwraps single-element arrays in nested properties. The `scope` field must be a JSON array even when there's only one entry. Using `,(New-BranchScope ...)` (unary comma operator) forces array semantics that survive serialization.

### Logging always writes, even with -WhatIf

PowerShell's `-WhatIf` propagates to all cmdlets that support it, including `Add-Content`. Logging is read-only intent — there's no value in skipping log writes during dry runs. The script's `Write-Log` function uses `Add-Content -WhatIf:$false -Confirm:$false` to bypass the propagation.

## Troubleshooting

### "Could not list projects. Check that ADO_PAT is set"

PAT isn't set in the environment, or doesn't have `Project (Read)` scope. Verify with:

```powershell
if ($env:ADO_PAT) { "PAT set, length: $($env:ADO_PAT.Length)" } else { "PAT not set" }
```

### "Group not found in N groups"

The principalName format may differ from what you typed. The script suggests similar-named groups when it can't find an exact match. Common formats:

- `[Project Name]\Group Name` (ADO standard)
- `Project Name\Group Name`
- `Domain\Group Name`

### "Failed to apply ... 400 (Bad Request) -- ADO says: ..."

The script extracts the actual ADO error message and logs the request body. Read the "ADO says" portion — it usually identifies the malformed field. Examples:

- `Expected '['` → an array field was sent as an object (usually fixed already in this version)
- `Error converting value to type 'System.Guid'` → wrong identity format (usually fixed)
- `The 'X' value is required` → a required field is missing from the body

If you hit one of these in a way the current script doesn't already handle, the script's `Invoke-PolicyPost` helper logs the full URL and body. Inspect those, compare to ADO's docs, and adjust the policy creator function accordingly.

### "Of those, 146 are scoped exactly..." but UI shows nothing

The script may have an older filter logic. The current version filters by `matchKind: Exact` + `repositoryId == target` + `refName == target`. If you see large discrepancies between the script's count and what's visible in the UI, your `Test-PolicyExists` function may not be filtering by scope — see the design notes above.

## Sample repos.txt format

```
# Comments start with #
# One repo name per line

sample-api-repo
sample-service-repo
sample-web-repo

# Add more as needed
```

## License

MIT — same as the parent repo.
