<#
.SYNOPSIS
    Configures Azure DevOps branch policies for Prisma Cloud PR gating.

.DESCRIPTION
    Applies a consistent set of branch policies to a target repo's protected branch:
      1. Require a minimum number of reviewers
      2. Automatically include a reviewer group (e.g., Code Review Approvers)
      3. Require comment resolution before merge
      4. Require Prisma Cloud status check to succeed

    Idempotent — safe to re-run. Skips policies already configured.
    Supports -WhatIf for dry-run mode.

    Prerequisites:
      - The target repo has been onboarded to Prisma Cloud (scanning is active)
      - At least one PR has been opened so Prisma has posted a status check
        (otherwise the status check name won't exist in ADO)
      - PAT with scope: Code (Read & Write), Project (Read & Write), Identity (Read)
      - You have Project Administrator on the target project

.PARAMETER Organization
    ADO organization name (the part after dev.azure.com/)

.PARAMETER Project
    ADO project name containing the repo

.PARAMETER RepoName
    Single repo name. Use either -RepoName or -RepoList.

.PARAMETER RepoList
    Array of repo names, or path to a text file with one repo name per line.

.PARAMETER Branch
    Branch to protect. Default: 'main'

.PARAMETER MinReviewers
    Minimum number of approvers required. Default: 1

.PARAMETER ReviewerGroup
    Identity descriptor for the auto-included reviewer group.
    Format: '[Project Name]\Group Name' (e.g., '[Your Project Name]\Code Review Approvers')

.PARAMETER PrismaStatusName
    Name of the Prisma Cloud status check as it appears in ADO.
    Default: 'Prisma Cloud / Code analysis'

.PARAMETER AllowSelfApproval
    Allow PR requestors to approve their own changes. Default: $false

.PARAMETER PatEnvVar
    Name of the environment variable holding the ADO PAT. Default: 'ADO_PAT'

.PARAMETER LogDir
    Directory for log files. Default: current directory.

.EXAMPLE
    # Dry run on a single repo
    .\Add-PrismaGate.ps1 -Organization "your-org" -Project "Your Project Name" `
        -RepoName "sample-api-repo" -Branch "test" `
        -ReviewerGroup "[Your Project Name]\Code Review Approvers" -WhatIf

.EXAMPLE
    # Apply for real
    .\Add-PrismaGate.ps1 -Organization "your-org" -Project "Your Project Name" `
        -RepoName "sample-service-repo" -Branch "main" `
        -ReviewerGroup "[Your Project Name]\Code Review Approvers"

.EXAMPLE
    # Bulk from a list file
    .\Add-PrismaGate.ps1 -Organization "your-org" -Project "Your Project Name" `
        -RepoList ".\repos.txt" -Branch "main" `
        -ReviewerGroup "[Your Project Name]\Code Review Approvers"

.EXAMPLE
    # Interactive mode — prompts for project, repos, branches, reviewer group.
    # Best for ad-hoc runs and when you don't remember exact repo/group names.
    .\Add-PrismaGate.ps1 -Interactive

.NOTES
    Author: Arash Farivarmoheb
    Run -WhatIf first. Always.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [Parameter(Mandatory = $true, ParameterSetName = 'Single')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$Organization,

    [Parameter(Mandatory = $true, ParameterSetName = 'Single')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Bulk')]
    [string]$Project,

    [Parameter(Mandatory = $true, ParameterSetName = 'Single')]
    [string]$RepoName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Bulk')]
    [object]$RepoList,

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [string]$Branch = 'main',

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [ValidateRange(1, 10)]
    [int]$MinReviewers = 1,

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [string]$ReviewerGroup,

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$PrismaStatusName = 'Prisma Cloud / Code analysis',

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [bool]$AllowSelfApproval = $false,

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$PatEnvVar = 'ADO_PAT',

    [Parameter(ParameterSetName = 'Single')]
    [Parameter(ParameterSetName = 'Bulk')]
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$LogDir = (Get-Location).Path
)

# =============================================================================
# Setup
# =============================================================================

$ErrorActionPreference = 'Stop'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "Add-PrismaGate_$timestamp.log"

$PolicyTypes = @{
    MinimumReviewers  = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'
    StatusCheck       = 'cbdc66da-9728-4af8-aada-9a5a32e4a226'
    CommentResolution = 'c6a1889d-b943-4856-b76f-9e46bb6b0df2'
    RequiredReviewer  = 'fd2167ab-b0be-447a-8ec8-39368250530e'
}

$ApiVersion = '7.1'
$BaseUrl  = "https://dev.azure.com/$Organization"
$VsspsUrl = "https://vssps.dev.azure.com/$Organization"

# =============================================================================
# Logging — bypass WhatIf so logs always write
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'SKIP', 'PLAN')]
        [string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"

    $color = switch ($Level) {
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        'SUCCESS' { 'Green' }
        'SKIP'    { 'DarkGray' }
        'PLAN'    { 'Cyan' }
        default   { 'White' }
    }

    Write-Host $line -ForegroundColor $color
    # Force write even in -WhatIf mode (logs are read-only intent)
    Add-Content -Path $logFile -Value $line -WhatIf:$false -Confirm:$false
}

# =============================================================================
# Auth
# =============================================================================

function Get-AuthHeader {
    $pat = [Environment]::GetEnvironmentVariable($PatEnvVar)
    if (-not $pat) {
        throw "PAT not found in environment variable '$PatEnvVar'. Set with: `$env:$PatEnvVar = 'your-pat'"
    }

    $pair    = ":$pat"
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    return @{
        Authorization  = "Basic $encoded"
        'Content-Type' = 'application/json'
    }
}

# =============================================================================
# Helpers
# =============================================================================

function Get-RepoId {
    param([string]$Name)

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/git/repositories/$([uri]::EscapeDataString($Name))?api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers (Get-AuthHeader) -Method Get
        return $response.id
    } catch {
        Write-Log "Could not resolve repo '$Name': $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

function Get-ExistingPolicies {
    param([string]$RepoId)

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/policy/configurations?repositoryId=$RepoId&refName=refs/heads/$Branch&api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers (Get-AuthHeader) -Method Get
        return $response.value
    } catch {
        Write-Log "Could not fetch existing policies: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Test-PolicyExists {
    param(
        [array]$ExistingPolicies,
        [string]$TypeId,
        [string]$RepoId
    )

    # Only count policies scoped EXACTLY to this repo + branch.
    # ADO returns policies from many scopes (project defaults, wildcard patterns,
    # repo-wide, inherited) when you query by ref. We only care about exact
    # branch-level matches on this specific repo.
    $expectedRef = "refs/heads/$Branch"

    $matched = $ExistingPolicies | Where-Object {
        $_.type.id -eq $TypeId -and
        $_.isEnabled -and
        $_.settings.scope -and
        ($_.settings.scope | Where-Object {
            $_.repositoryId -eq $RepoId -and
            $_.refName -eq $expectedRef -and
            $_.matchKind -eq 'Exact'
        })
    }

    return ($matched.Count -gt 0)
}

function Resolve-GroupDescriptor {
    param([string]$GroupName)

    Write-Log "  Looking up reviewer group: '$GroupName'"

    # Graph API requires Identity (Read) and Graph (Read) scopes on the PAT
    $url = "$VsspsUrl/_apis/graph/groups?api-version=$ApiVersion-preview.1"
    $allGroups = @()
    $continuationToken = $null

    try {
        # Page through all groups (default page size ~500)
        do {
            $pagedUrl = if ($continuationToken) { "$url&continuationToken=$continuationToken" } else { $url }
            $response = Invoke-WebRequest -Uri $pagedUrl -Headers (Get-AuthHeader) -Method Get -UseBasicParsing
            $data = $response.Content | ConvertFrom-Json
            $allGroups += $data.value

            $continuationToken = $response.Headers['X-MS-ContinuationToken']
            if ($continuationToken -is [array]) { $continuationToken = $continuationToken[0] }
        } while ($continuationToken)

        Write-Log "  Retrieved $($allGroups.Count) total groups from ADO"

        # Match strategies in order
        $group = $allGroups | Where-Object { $_.principalName -eq $GroupName }

        if (-not $group) {
            $displayMatch = $allGroups | Where-Object { $_.displayName -eq ($GroupName -replace '^\[.*?\]\\', '') }
            if ($displayMatch) {
                Write-Log "  Found a group by displayName instead of principalName: $($displayMatch.principalName)" -Level WARN
                $group = $displayMatch
            }
        }

        if (-not $group) {
            $group = $allGroups | Where-Object { $_.principalName -ieq $GroupName }
        }

        if (-not $group) {
            Write-Log "  Group '$GroupName' not found in $($allGroups.Count) groups." -Level ERROR
            $similar = $allGroups | Where-Object { $_.displayName -match 'merge|council|review' } | Select-Object -First 5
            if ($similar) {
                Write-Log '  Did you mean one of these (sample matches by display name)?' -Level WARN
                foreach ($s in $similar) {
                    Write-Log "    principalName: $($s.principalName)" -Level WARN
                }
            }
            return $null
        }

        Write-Log "  Group found: principalName=$($group.principalName)"

        # The required-reviewer policy needs the identity GUID (not the descriptor).
        # Query the identities endpoint, then return the .id field (a GUID).
        $encodedDescriptor = [uri]::EscapeDataString($group.descriptor)
        $identityUrl = "$VsspsUrl/_apis/identities?subjectDescriptors=$encodedDescriptor&api-version=$ApiVersion-preview.1"

        try {
            $identity = Invoke-RestMethod -Uri $identityUrl -Headers (Get-AuthHeader) -Method Get

            if ($identity.value -and $identity.value.Count -gt 0) {
                $entry = $identity.value[0]
                if ($entry.id) {
                    Write-Log "  Resolved identity GUID: $($entry.id)"
                    if ($entry.descriptor) {
                        Write-Log "  (legacy descriptor also available: $($entry.descriptor))"
                    }
                    return $entry.id
                }
            }
            Write-Log "  Identity lookup returned no GUID — will try fallback" -Level WARN
        } catch {
            Write-Log "  Identity conversion endpoint failed: $($_.Exception.Message)" -Level WARN
        }

        # Fallback: try resolving by group origin id
        try {
            if ($group.originId) {
                Write-Log "  Trying fallback: lookup by originId $($group.originId)"
                $altUrl = "$VsspsUrl/_apis/identities?searchFilter=DirectoryAlias&filterValue=$([uri]::EscapeDataString($group.principalName))&api-version=$ApiVersion-preview.1"
                $altIdentity = Invoke-RestMethod -Uri $altUrl -Headers (Get-AuthHeader) -Method Get
                if ($altIdentity.value -and $altIdentity.value.Count -gt 0 -and $altIdentity.value[0].id) {
                    Write-Log "  Fallback resolved GUID: $($altIdentity.value[0].id)"
                    return $altIdentity.value[0].id
                }
            }
        } catch {
            Write-Log "  Fallback identity lookup also failed: $($_.Exception.Message)" -Level WARN
        }

        Write-Log "  Could not resolve identity GUID for $($group.principalName)" -Level ERROR
        return $null

    } catch {
        Write-Log "  Group lookup failed: $($_.Exception.Message)" -Level ERROR
        Write-Log '  Verify your PAT has these scopes: Identity (Read), Graph (Read), Member Entitlement Management (Read)' -Level ERROR
        return $null
    }
}

function New-BranchScope {
    param([string]$RepoId)

    # Returns a single scope entry as a hash. Callers MUST wrap with comma
    # operator at assignment: scope = ,(New-BranchScope ...) to force
    # JSON array form. ConvertTo-Json silently unwraps single-element arrays
    # in nested properties otherwise.
    return [ordered]@{
        repositoryId = $RepoId
        refName      = "refs/heads/$Branch"
        matchKind    = 'Exact'
    }
}

function Invoke-PolicyPost {
    <#
    Posts a policy configuration to ADO and returns the response.
    On error, extracts the actual ADO error message (not just the HTTP code)
    so we can see what was actually wrong with the request.
    Works in both Windows PowerShell 5.x and PowerShell 7+.
    #>
    param(
        [string]$Url,
        [string]$Body
    )

    try {
        return Invoke-RestMethod -Uri $Url -Headers (Get-AuthHeader) -Method Post -Body $Body
    } catch {
        $baseMessage = $_.Exception.Message
        $errorBody = $null

        # PowerShell 7 puts the response body here
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errorBody = $_.ErrorDetails.Message
        }

        # Windows PowerShell 5 puts it on the response stream
        if (-not $errorBody) {
            try {
                $response = $_.Exception.Response
                if ($response -and $response.GetResponseStream) {
                    $stream = $response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errorBody = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                }
            } catch {
                # If reading the stream fails, leave $errorBody as $null
            }
        }

        # Log the failing request for debugging
        Write-Log "    DEBUG URL: $Url" -Level ERROR
        Write-Log "    DEBUG BODY: $Body" -Level ERROR

        if ($errorBody) {
            try {
                $parsed = $errorBody | ConvertFrom-Json
                if ($parsed.message) {
                    throw "$baseMessage -- ADO says: $($parsed.message)"
                }
            } catch {
                # Not JSON, fall through to raw body
            }
            throw "$baseMessage -- ADO response: $errorBody"
        }

        throw $baseMessage
    }
}

# =============================================================================
# Policy creators
#
# Each policy function checks $PSCmdlet.ShouldProcess to handle -WhatIf properly.
# In WhatIf mode, ShouldProcess returns $false, we log the plan, no API call.
# In live mode, ShouldProcess returns $true, we make the API call.
# =============================================================================

function Set-MinimumReviewersPolicy {
    param([string]$RepoId, [string]$RepoName)

    $action = "Set minimum reviewers ($MinReviewers required, self-approval=$AllowSelfApproval)"

    if (-not $PSCmdlet.ShouldProcess("$RepoName/$Branch", $action)) {
        Write-Log "  [PLAN] $action" -Level PLAN
        return
    }

    $body = @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $PolicyTypes.MinimumReviewers }
        settings   = @{
            minimumApproverCount       = $MinReviewers
            creatorVoteCounts          = $AllowSelfApproval
            allowDownvotes             = $false
            resetOnSourcePush          = $true
            requireVoteOnLastIteration = $false
            scope                      = ,(New-BranchScope -RepoId $RepoId)
        }
    } | ConvertTo-Json -Depth 10

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/policy/configurations?api-version=$ApiVersion"
    Invoke-PolicyPost -Url $url -Body $body | Out-Null
    Write-Log "  ✓ Minimum reviewers policy applied (min=$MinReviewers, self-approval=$AllowSelfApproval)" -Level SUCCESS
}

function Set-CommentResolutionPolicy {
    param([string]$RepoId, [string]$RepoName)

    $action = 'Require comment resolution before merge'

    if (-not $PSCmdlet.ShouldProcess("$RepoName/$Branch", $action)) {
        Write-Log "  [PLAN] $action" -Level PLAN
        return
    }

    $body = @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $PolicyTypes.CommentResolution }
        settings   = @{
            scope = ,(New-BranchScope -RepoId $RepoId)
        }
    } | ConvertTo-Json -Depth 10

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/policy/configurations?api-version=$ApiVersion"
    Invoke-PolicyPost -Url $url -Body $body | Out-Null
    Write-Log '  ✓ Comment resolution policy applied' -Level SUCCESS
}

function Set-RequiredReviewerGroupPolicy {
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$GroupDescriptor
    )

    $action = "Add required reviewer group '$ReviewerGroup'"

    if (-not $PSCmdlet.ShouldProcess("$RepoName/$Branch", $action)) {
        Write-Log "  [PLAN] $action" -Level PLAN
        return
    }

    $body = @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $PolicyTypes.RequiredReviewer }
        settings   = @{
            requiredReviewerIds  = @($GroupDescriptor)
            filenamePatterns     = @()
            addedFilesOnly       = $false
            message              = "At least one approval must come from the $ReviewerGroup group."
            minimumApproverCount = 1
            creatorVoteCounts    = $AllowSelfApproval
            scope                = ,(New-BranchScope -RepoId $RepoId)
        }
    } | ConvertTo-Json -Depth 10

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/policy/configurations?api-version=$ApiVersion"
    Invoke-PolicyPost -Url $url -Body $body | Out-Null
    Write-Log "  ✓ Required reviewer group policy applied ($ReviewerGroup)" -Level SUCCESS
}

function Set-PrismaStatusCheckPolicy {
    param([string]$RepoId, [string]$RepoName)

    $action = "Add required status check '$PrismaStatusName'"

    if (-not $PSCmdlet.ShouldProcess("$RepoName/$Branch", $action)) {
        Write-Log "  [PLAN] $action" -Level PLAN
        return
    }

    # Status names in ADO are "genre/name" — split on the slash
    $parts = $PrismaStatusName -split ' / ', 2
    if ($parts.Count -eq 2) {
        $genre = $parts[0]
        $name  = $parts[1]
    } else {
        $genre = 'Prisma Cloud'
        $name  = $PrismaStatusName
    }

    $body = @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $PolicyTypes.StatusCheck }
        settings   = @{
            statusName               = $name
            statusGenre              = $genre
            authorId                 = $null
            invalidateOnSourceUpdate = $true
            policyApplicability      = 0  # 0 = required for all PRs
            scope                    = ,(New-BranchScope -RepoId $RepoId)
        }
    } | ConvertTo-Json -Depth 10

    $url = "$BaseUrl/$([uri]::EscapeDataString($Project))/_apis/policy/configurations?api-version=$ApiVersion"
    Invoke-PolicyPost -Url $url -Body $body | Out-Null
    Write-Log "  ✓ Status check policy applied ($PrismaStatusName)" -Level SUCCESS
}

# =============================================================================
# Main repo processor
# =============================================================================

function Invoke-RepoConfiguration {
    param([string]$Name)

    Write-Log ''
    Write-Log "==== Processing: $Name ===="

    $repoId = Get-RepoId -Name $Name
    if (-not $repoId) {
        Write-Log "Skipping $Name (could not resolve repo ID)" -Level ERROR
        return [PSCustomObject]@{ Repo = $Name; Status = 'Failed'; Reason = 'Repo not found' }
    }
    Write-Log "  Repo ID: $repoId"

    $existing = Get-ExistingPolicies -RepoId $repoId
    $expectedRef = "refs/heads/$Branch"
    $exactlyScoped = $existing | Where-Object {
        $_.settings.scope -and
        ($_.settings.scope | Where-Object {
            $_.repositoryId -eq $repoId -and
            $_.refName -eq $expectedRef -and
            $_.matchKind -eq 'Exact'
        })
    }
    Write-Log "  Found $($existing.Count) total policies returned by API for refs/heads/$Branch"
    Write-Log "  Of those, $($exactlyScoped.Count) are scoped exactly to this repo + branch (the rest are inherited/wildcard/repo-wide)"

    $applied = @()
    $skipped = @()
    $planned = @()

    # 1. Minimum reviewers
    if (Test-PolicyExists -ExistingPolicies $existing -TypeId $PolicyTypes.MinimumReviewers -RepoId $repoId) {
        Write-Log '  Minimum reviewers policy already exists' -Level SKIP
        $skipped += 'MinReviewers'
    } else {
        try {
            Set-MinimumReviewersPolicy -RepoId $repoId -RepoName $Name
            if ($WhatIfPreference) { $planned += 'MinReviewers' } else { $applied += 'MinReviewers' }
        } catch {
            Write-Log "  Failed to apply minimum reviewers: $($_.Exception.Message)" -Level ERROR
        }
    }

    # 2. Comment resolution
    if (Test-PolicyExists -ExistingPolicies $existing -TypeId $PolicyTypes.CommentResolution -RepoId $repoId) {
        Write-Log '  Comment resolution policy already exists' -Level SKIP
        $skipped += 'CommentResolution'
    } else {
        try {
            Set-CommentResolutionPolicy -RepoId $repoId -RepoName $Name
            if ($WhatIfPreference) { $planned += 'CommentResolution' } else { $applied += 'CommentResolution' }
        } catch {
            Write-Log "  Failed to apply comment resolution: $($_.Exception.Message)" -Level ERROR
        }
    }

    # 3. Required reviewer group (optional)
    if ($ReviewerGroup) {
        if (Test-PolicyExists -ExistingPolicies $existing -TypeId $PolicyTypes.RequiredReviewer -RepoId $repoId) {
            Write-Log '  Required reviewer policy already exists (manually verify the group is correct)' -Level SKIP
            $skipped += 'RequiredReviewer'
        } else {
            try {
                $descriptor = Resolve-GroupDescriptor -GroupName $ReviewerGroup
                if ($descriptor) {
                    Set-RequiredReviewerGroupPolicy -RepoId $repoId -RepoName $Name -GroupDescriptor $descriptor
                    if ($WhatIfPreference) { $planned += 'RequiredReviewer' } else { $applied += 'RequiredReviewer' }
                } else {
                    Write-Log '  Could not resolve group, skipping required reviewer policy' -Level WARN
                }
            } catch {
                Write-Log "  Failed to apply required reviewer: $($_.Exception.Message)" -Level ERROR
            }
        }
    }

    # 4. Prisma status check
    $hasPrismaStatus = $false
    if (Test-PolicyExists -ExistingPolicies $existing -TypeId $PolicyTypes.StatusCheck -RepoId $repoId) {
        $expectedRef = "refs/heads/$Branch"
        # Filter to status checks scoped exactly to this repo + branch
        $statusChecks = $existing | Where-Object {
            $_.type.id -eq $PolicyTypes.StatusCheck -and
            $_.isEnabled -and
            $_.settings.scope -and
            ($_.settings.scope | Where-Object {
                $_.repositoryId -eq $repoId -and
                $_.refName -eq $expectedRef -and
                $_.matchKind -eq 'Exact'
            })
        }
        $prismaCheck = $statusChecks | Where-Object {
            $_.settings.statusName -match 'Code analysis' -or $_.settings.statusGenre -match 'Prisma'
        }
        $hasPrismaStatus = [bool]$prismaCheck
    }

    if ($hasPrismaStatus) {
        Write-Log '  Prisma status check policy already exists' -Level SKIP
        $skipped += 'PrismaStatusCheck'
    } else {
        try {
            Set-PrismaStatusCheckPolicy -RepoId $repoId -RepoName $Name
            if ($WhatIfPreference) { $planned += 'PrismaStatusCheck' } else { $applied += 'PrismaStatusCheck' }
        } catch {
            Write-Log "  Failed to apply Prisma status check: $($_.Exception.Message)" -Level ERROR
        }
    }

    $status = if ($WhatIfPreference -and $planned.Count -gt 0) {
        'Planned'
    } elseif ($applied.Count -gt 0) {
        'Applied'
    } elseif ($skipped.Count -gt 0) {
        'AlreadyConfigured'
    } else {
        'NoChanges'
    }

    return [PSCustomObject]@{
        Repo    = $Name
        Status  = $status
        Applied = ($applied -join ', ')
        Planned = ($planned -join ', ')
        Skipped = ($skipped -join ', ')
    }
}

# =============================================================================
# Interactive mode helpers
# =============================================================================

function Get-AdoProjects {
    param([string]$Org)

    $url = "https://dev.azure.com/$Org/_apis/projects?api-version=$ApiVersion&`$top=500"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers (Get-AuthHeader) -Method Get
        return $response.value | Sort-Object name
    } catch {
        Write-Host "Failed to list projects: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Get-AdoRepos {
    param(
        [string]$Org,
        [string]$ProjectName
    )

    $url = "https://dev.azure.com/$Org/$([uri]::EscapeDataString($ProjectName))/_apis/git/repositories?api-version=$ApiVersion"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers (Get-AuthHeader) -Method Get
        return $response.value | Sort-Object name
    } catch {
        Write-Host "Failed to list repos: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Get-RepoDefaultBranch {
    param([object]$Repo)

    # The defaultBranch field comes back as "refs/heads/main" — strip the prefix
    if ($Repo.defaultBranch) {
        return ($Repo.defaultBranch -replace '^refs/heads/', '')
    }
    return 'main'
}

function Select-FromList {
    <#
    Generic single-select prompt from a list. Returns the selected item or $null if cancelled.
    Items can be strings or objects (with -DisplayProperty to pick what to show).
    #>
    param(
        [array]$Items,
        [string]$Prompt,
        [string]$DisplayProperty
    )

    if ($Items.Count -eq 0) {
        Write-Host 'No items to choose from.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $display = if ($DisplayProperty) { $Items[$i].$DisplayProperty } else { $Items[$i] }
        Write-Host ("  {0,3}. {1}" -f ($i + 1), $display)
    }
    Write-Host ''

    while ($true) {
        $userInput = Read-Host "$Prompt (1-$($Items.Count), or 'q' to quit)"
        if ($userInput -eq 'q') { return $null }

        $num = 0
        if ([int]::TryParse($userInput, [ref]$num) -and $num -ge 1 -and $num -le $Items.Count) {
            return $Items[$num - 1]
        }
        Write-Host "Invalid selection. Enter a number between 1 and $($Items.Count)." -ForegroundColor Yellow
    }
}

function Select-ReposMultiSelect {
    <#
    Multi-select picker. Tries Out-GridView first (best UX on Windows with GUI).
    Falls back to console multi-select with comma-separated numbers if Out-GridView fails.
    #>
    param([array]$Repos)

    # Try Out-GridView first
    try {
        $selected = $Repos |
            Select-Object @{Name='Repo'; Expression={$_.name}}, @{Name='DefaultBranch'; Expression={Get-RepoDefaultBranch $_}}, @{Name='Size'; Expression={if ($_.size) { "$([math]::Round($_.size / 1MB, 1)) MB" } else { 'n/a' }}} |
            Out-GridView -Title 'Select repos to gate (Ctrl+Click for multi-select)' -OutputMode Multiple

        if ($selected) {
            # Map back to full repo objects
            $selectedNames = $selected | ForEach-Object { $_.Repo }
            return $Repos | Where-Object { $selectedNames -contains $_.name }
        }
        return @()
    } catch {
        Write-Host "Out-GridView not available, falling back to console picker..." -ForegroundColor Yellow
    }

    # Console fallback
    Write-Host ''
    Write-Host "Available repos:"
    for ($i = 0; $i -lt $Repos.Count; $i++) {
        $branch = Get-RepoDefaultBranch $Repos[$i]
        Write-Host ("  {0,3}. {1}  (default: {2})" -f ($i + 1), $Repos[$i].name, $branch)
    }
    Write-Host ''
    Write-Host "Enter numbers separated by commas, ranges with dashes (e.g., '1,3,5-8'), or 'all'"
    $userInput = Read-Host 'Select repos'

    if ($userInput -eq 'all') { return $Repos }
    if (-not $userInput) { return @() }

    $indices = @()
    foreach ($part in $userInput -split ',') {
        $part = $part.Trim()
        if ($part -match '^(\d+)-(\d+)$') {
            $start = [int]$matches[1]
            $end = [int]$matches[2]
            $indices += ($start..$end)
        } elseif ($part -match '^\d+$') {
            $indices += [int]$part
        }
    }

    $indices = $indices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $Repos.Count }
    return $indices | ForEach-Object { $Repos[$_ - 1] }
}

function Get-ReviewerGroupsForProject {
    param([string]$ProjectName)

    $url = "$VsspsUrl/_apis/graph/groups?api-version=$ApiVersion-preview.1"
    $allGroups = @()
    $continuationToken = $null

    try {
        do {
            $pagedUrl = if ($continuationToken) { "$url&continuationToken=$continuationToken" } else { $url }
            $response = Invoke-WebRequest -Uri $pagedUrl -Headers (Get-AuthHeader) -Method Get -UseBasicParsing
            $data = $response.Content | ConvertFrom-Json
            $allGroups += $data.value

            $continuationToken = $response.Headers['X-MS-ContinuationToken']
            if ($continuationToken -is [array]) { $continuationToken = $continuationToken[0] }
        } while ($continuationToken)
    } catch {
        Write-Host "Failed to list groups: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    # Filter to groups that look project-scoped. PowerShell's -like treats [ and ]
    # as wildcards, so we use string method .Contains() instead. We check both
    # [ProjectName] (ADO standard format) and plain ProjectName (some tenants).
    $bracketedName = "[$ProjectName]"
    $projectScoped = $allGroups | Where-Object {
        $_.principalName -and (
            $_.principalName.Contains($bracketedName) -or
            $_.principalName.StartsWith("$ProjectName\") -or
            ($_.domain -and $_.domain.Contains($ProjectName))
        )
    }

    # If nothing matched the project scope, fall back to returning all groups
    # — better to show too many than zero
    if ($projectScoped.Count -eq 0) {
        Write-Host "  Note: no groups matched the project scope filter, showing all groups" -ForegroundColor DarkGray
        return $allGroups | Sort-Object principalName
    }

    return $projectScoped | Sort-Object principalName
}

function Invoke-InteractiveMode {
    <#
    Runs the interactive flow and returns a hashtable of selections.
    Returns $null if user cancelled.
    #>

    Write-Host ''
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host '  Add-PrismaGate (interactive mode)' -ForegroundColor Cyan
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host ''

    # Step 1: Organization
    $org = if ($script:Organization) { $script:Organization } else { 'your-org' }
    $orgInput = Read-Host "Organization [$org]"
    if ($orgInput) { $org = $orgInput }
    # Update the global so Get-AuthHeader etc. work
    $script:Organization = $org
    $script:BaseUrl = "https://dev.azure.com/$org"
    $script:VsspsUrl = "https://vssps.dev.azure.com/$org"

    # Step 2: Verify PAT works by trying to list projects
    Write-Host ''
    Write-Host "Discovering projects in $org..." -ForegroundColor Cyan
    $projects = Get-AdoProjects -Org $org
    if ($projects.Count -eq 0) {
        Write-Host "Could not list projects. Check that ADO_PAT is set and has 'Project (Read)' scope." -ForegroundColor Red
        return $null
    }
    Write-Host "Found $($projects.Count) projects."

    $selectedProject = Select-FromList -Items $projects -Prompt 'Select a project' -DisplayProperty 'name'
    if (-not $selectedProject) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return $null
    }

    # Step 3: Discover repos in the project
    Write-Host ''
    Write-Host "Discovering repos in '$($selectedProject.name)'..." -ForegroundColor Cyan
    $repos = Get-AdoRepos -Org $org -ProjectName $selectedProject.name
    if ($repos.Count -eq 0) {
        Write-Host 'No repos found in that project.' -ForegroundColor Yellow
        return $null
    }
    Write-Host "Found $($repos.Count) repos."

    $selectedRepos = Select-ReposMultiSelect -Repos $repos
    if ($selectedRepos.Count -eq 0) {
        Write-Host 'No repos selected. Cancelled.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    Write-Host "You selected $($selectedRepos.Count) repos:" -ForegroundColor Green
    foreach ($r in $selectedRepos) {
        Write-Host "  - $($r.name)"
    }

    # Step 4: Branch detection per repo
    Write-Host ''
    Write-Host 'Auto-detected default branches:' -ForegroundColor Cyan
    $repoBranches = @()
    foreach ($r in $selectedRepos) {
        $branch = Get-RepoDefaultBranch $r
        $repoBranches += [PSCustomObject]@{ Repo = $r.name; Branch = $branch }
        Write-Host ("  {0,-40} -> {1}" -f $r.name, $branch)
    }

    Write-Host ''
    $override = Read-Host 'Override any of these? [N/y]'
    if ($override -eq 'y') {
        for ($i = 0; $i -lt $repoBranches.Count; $i++) {
            $current = $repoBranches[$i]
            $newBranch = Read-Host "  $($current.Repo) [$($current.Branch)]"
            if ($newBranch) { $repoBranches[$i].Branch = $newBranch }
        }
    }

    # Step 5: Reviewer group discovery
    Write-Host ''
    Write-Host "Discovering reviewer groups in '[$($selectedProject.name)]'..." -ForegroundColor Cyan
    $groups = Get-ReviewerGroupsForProject -ProjectName $selectedProject.name
    Write-Host "Found $($groups.Count) groups in project scope."

    # Suggest groups matching merge/council/review patterns
    $suggested = $groups | Where-Object { $_.displayName -match 'merge|council|review|approver' }

    $reviewerGroup = $null
    if ($suggested.Count -eq 1) {
        Write-Host ''
        Write-Host "Suggested reviewer group:" -ForegroundColor Green
        Write-Host "  $($suggested[0].principalName)"
        $useIt = Read-Host 'Use this reviewer group? [Y/n]'
        if ($useIt -ne 'n') {
            $reviewerGroup = $suggested[0].principalName
        }
    } elseif ($suggested.Count -gt 1) {
        Write-Host ''
        Write-Host 'Multiple matching groups found:' -ForegroundColor Cyan
        $picked = Select-FromList -Items $suggested -Prompt 'Select a reviewer group (or q for none)' -DisplayProperty 'principalName'
        if ($picked) { $reviewerGroup = $picked.principalName }
    } else {
        Write-Host ''
        Write-Host 'No groups matched merge/council/review patterns.' -ForegroundColor Yellow
        $browse = Read-Host 'Browse all groups in project? [y/N]'
        if ($browse -eq 'y' -and $groups.Count -gt 0) {
            $picked = Select-FromList -Items $groups -Prompt 'Select a reviewer group (or q for none)' -DisplayProperty 'principalName'
            if ($picked) { $reviewerGroup = $picked.principalName }
        }
    }

    # Step 6: Confirm and pick run mode
    Write-Host ''
    Write-Host '===============================================================' -ForegroundColor Cyan
    Write-Host '  Configuration summary' -ForegroundColor Cyan
    Write-Host '==============================================================='
    Write-Host "  Organization:   $org"
    Write-Host "  Project:        $($selectedProject.name)"
    Write-Host "  Min reviewers:  $MinReviewers"
    Write-Host "  Reviewer group: $(if ($reviewerGroup) { $reviewerGroup } else { '(none)' })"
    Write-Host "  Status check:   $PrismaStatusName"
    Write-Host '  Repos & branches:'
    foreach ($rb in $repoBranches) {
        Write-Host ("    {0}/{1}" -f $rb.Repo, $rb.Branch)
    }
    Write-Host ''

    $mode = Read-Host 'Run mode: [W]hatIf / [L]ive / [C]ancel'
    $mode = $mode.ToLower()

    if ($mode -notin @('w', 'l', 'whatif', 'live')) {
        Write-Host 'Cancelled.' -ForegroundColor Yellow
        return $null
    }

    return @{
        Organization  = $org
        Project       = $selectedProject.name
        RepoBranches  = $repoBranches
        ReviewerGroup = $reviewerGroup
        WhatIf        = ($mode -in @('w', 'whatif'))
    }
}

# =============================================================================
# Main
# =============================================================================

try {
    # Verify PAT before doing anything
    $null = Get-AuthHeader

    # Interactive mode: discover and prompt for everything, then proceed
    if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
        $selections = Invoke-InteractiveMode
        if (-not $selections) {
            Write-Host 'Interactive mode cancelled. Exiting.' -ForegroundColor Yellow
            exit 0
        }

        # Apply selections to script-level variables
        $script:Organization = $selections.Organization
        $script:Project      = $selections.Project
        $script:ReviewerGroup = $selections.ReviewerGroup
        # WhatIf gets applied to the cmdlet-level preference
        if ($selections.WhatIf) { $WhatIfPreference = $true }

        # Reset BaseUrl/VsspsUrl in case Organization changed
        $script:BaseUrl  = "https://dev.azure.com/$Organization"
        $script:VsspsUrl = "https://vssps.dev.azure.com/$Organization"
    }

    Write-Log '==============================================================='
    Write-Log 'Add-PrismaGate.ps1 starting'
    Write-Log "Organization : $Organization"
    Write-Log "Project      : $Project"
    Write-Log "MinReviewers : $MinReviewers"
    Write-Log "ReviewerGroup: $(if ($ReviewerGroup) { $ReviewerGroup } else { '(none)' })"
    Write-Log "StatusCheck  : $PrismaStatusName"
    Write-Log "Mode         : $(if ($WhatIfPreference) { 'DRY RUN (-WhatIf)' } else { 'LIVE' })"
    Write-Log "Log file     : $logFile"
    Write-Log '==============================================================='

    # Build the work list: each entry has a repo name and a target branch
    $workItems = @()

    if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
        foreach ($rb in $selections.RepoBranches) {
            $workItems += [PSCustomObject]@{ Repo = $rb.Repo; Branch = $rb.Branch }
        }
    } elseif ($PSCmdlet.ParameterSetName -eq 'Single') {
        $workItems += [PSCustomObject]@{ Repo = $RepoName; Branch = $Branch }
    } else {
        # Bulk mode
        $repoNames = @()
        if ($RepoList -is [string] -and (Test-Path $RepoList)) {
            $repoNames = Get-Content -Path $RepoList | Where-Object { $_ -and -not $_.StartsWith('#') }
        } elseif ($RepoList -is [array]) {
            $repoNames = $RepoList
        } else {
            throw "RepoList must be an array of repo names or a path to a text file (one repo per line, '#' for comments)"
        }
        foreach ($r in $repoNames) {
            $r = $r.Trim()
            if ($r) { $workItems += [PSCustomObject]@{ Repo = $r; Branch = $Branch } }
        }
    }

    Write-Log "Repos to process: $($workItems.Count)"

    # Process each repo. Set $script:Branch before each call because the worker
    # functions read $Branch from script scope (Get-ExistingPolicies, New-BranchScope, etc.)
    $results = @()
    foreach ($item in $workItems) {
        $script:Branch = $item.Branch
        $result = Invoke-RepoConfiguration -Name $item.Repo
        # Augment the result with branch info so the summary shows it
        $result | Add-Member -NotePropertyName 'Branch' -NotePropertyValue $item.Branch -Force
        $results += $result
    }

    # Summary
    Write-Log ''
    Write-Log '==============================================================='
    Write-Log 'SUMMARY'
    Write-Log '==============================================================='

    $results | Format-Table -AutoSize Repo, Branch, Status, Applied, Planned, Skipped | Out-String | Write-Host

    $appliedCount  = ($results | Where-Object Status -eq 'Applied').Count
    $plannedCount  = ($results | Where-Object Status -eq 'Planned').Count
    $alreadyCount  = ($results | Where-Object Status -eq 'AlreadyConfigured').Count
    $noChangeCount = ($results | Where-Object Status -eq 'NoChanges').Count
    $failedCount   = ($results | Where-Object Status -eq 'Failed').Count

    if ($WhatIfPreference) {
        Write-Log "Planned (would apply) : $plannedCount"
    } else {
        Write-Log "Applied               : $appliedCount"
    }
    Write-Log "Already configured    : $alreadyCount"
    Write-Log "No changes            : $noChangeCount"
    Write-Log "Failed                : $failedCount"
    Write-Log ''
    Write-Log "Log file: $logFile"

    if ($WhatIfPreference) {
        Write-Log ''
        Write-Log 'This was a DRY RUN. Re-run without -WhatIf to apply changes.' -Level WARN
    }

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
