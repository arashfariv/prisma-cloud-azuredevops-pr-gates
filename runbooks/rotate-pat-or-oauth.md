# Runbook: Rotate Prisma Cloud authentication (PAT or OAuth)

## When to use this runbook

- Existing PAT is approaching expiry (set a reminder 30 days before)
- OAuth grant is broken because the authorizing user left the org
- Migrating from personal account to service account
- Annual credential rotation per security policy
- Suspected credential compromise

## Pre-rotation checklist

Before rotating, gather:

- [ ] Name of the existing integration (Prisma Cloud → Settings → Providers → Repositories tab)
- [ ] Account that authorized the existing integration
- [ ] Service account credentials (if migrating)
- [ ] List of repos currently onboarded (export from Providers page for reference)
- [ ] Maintenance window or off-hours timing (rotation briefly interrupts scans)

## Path A: Rotate a PAT

### 1. Generate the new PAT

In ADO:

1. Profile icon (top right) → **Personal access tokens** → **+ New Token**
2. Settings:
   - **Name:** `prisma-cloud-{env}-{date}` (e.g., `prisma-cloud-prod-2026-04`)
   - **Organization:** the ADO org containing the repos
   - **Expiration:** 1 year (max)
   - **Scopes (Custom defined):**
     - Code: Read & Write
     - Project and Team: Read
     - Pull Request Threads: Read & Write
     - Member Entitlement Management: Read
     - Graph: Read
3. Create. **Copy the token immediately** — you'll never see it again.

### 2. Update the integration in Prisma Cloud

1. **Settings → Providers → Repositories tab → click `•••` on the integration → Manage VCS User Tokens** (or Edit, depending on UI version)
2. Paste the new PAT
3. Save

### 3. Verify

1. Open a test PR on any onboarded repo
2. Wait 2-5 min
3. Confirm Prisma posts a status check normally

If scans don't fire: token scopes may be insufficient. Verify the Custom Defined scopes match the list above.

### 4. Set the next reminder

Calendar reminder: 30 days before the new PAT's expiration date.

### 5. Revoke the old PAT

In ADO → Personal access tokens → find old PAT → **Revoke**

Don't skip this. Revoking immediately closes the security window.

## Path B: Rotate an OAuth grant

OAuth grants don't expire on a schedule, but they break when the authorizing user's account is disabled. This is mostly a "user left the org" scenario.

### 1. Identify the new authorizing identity

Strongly recommended: **service account**, not a person. Naming convention: `svc-prismacloud@yourcompany.com` or similar.

Service account requirements:
- ADO license (basic is fine)
- Membership in projects containing repos to scan
- Project Administrator on at least one project (for OAuth flow)

### 2. Sign in as the new identity

In an incognito window or a different browser:

1. Sign into `dev.azure.com` as the service account
2. Confirm you can access the projects/repos in scope

### 3. Re-authorize the integration

In Prisma Cloud (still signed in as your normal account):

1. **Settings → Providers → Repositories tab → click `•••` on the integration → re-authorize** (exact wording varies)
2. The OAuth flow opens — make sure the ADO popup is using the service account, not your personal account
3. Review permissions, click Accept

If the OAuth popup is using the wrong account, sign out of ADO in that session first.

### 4. Verify

Same as Path A step 3. Open a test PR, confirm scan + status post.

### 5. Revoke the old OAuth grant

Have the previous authorizer (or an admin if their account is disabled) revoke the old grant:

1. ADO → User Settings → **Authorizations**
2. Find "Prisma Cloud Code Security"
3. Revoke

If the previous authorizer's account is disabled, the grant is already broken; this step is optional but cleans up the audit trail.

## Path C: Migrate from PAT to OAuth (or vice versa)

Sometimes you want to consolidate auth method.

### Migration: PAT → OAuth

Recommended for long-term operation. OAuth doesn't expire, doesn't need rotation.

1. Set up a new integration using OAuth (same as Path B above)
2. Migrate repos from old PAT-based integration to new OAuth-based integration:
   - In old integration, list onboarded repos
   - Remove repos from old integration
   - Add same repos to new integration
3. Verify scans run on new integration
4. Delete old integration
5. Revoke the PAT in ADO

### Migration: OAuth → PAT

Less common but valid for some isolated environments where OAuth isn't available.

Reverse of above. Remove from OAuth integration, add to PAT integration.

## Validation checklist (any rotation path)

After rotation, verify:

- [ ] Test PR on a known-onboarded repo gets a Prisma status check
- [ ] Scheduled scans continued (check `Last Scan Date` on Providers page within last 24 hours)
- [ ] No errors in Prisma Cloud's audit log for the integration
- [ ] No service hooks broken in ADO (Project Settings → Service hooks)
- [ ] Set the next rotation reminder

## Common issues

### "Token scope insufficient" after PAT rotation

The new PAT was created with fewer scopes than the old one. Re-create with the full scope list and try again.

### Scans stop after OAuth migration

Service hooks may have been keyed to the old grant. Re-create them by:

1. Removing one repo from the integration and re-adding it (forces hook recreation)
2. Or manually creating service hooks pointing to the same Prisma webhook URL

### Old PAT keeps working alongside new one

By design — ADO PATs are independent until revoked. Revoke the old one explicitly.

### OAuth flow won't accept the service account

Some service accounts have restrictions on third-party OAuth grants. May need to:
- Allow the service account to authorize external apps (org-level setting)
- Use a different service account
- Fall back to PAT-based auth temporarily

## Documentation to update

After rotation:

- [ ] Internal runbook (this one) with date of rotation
- [ ] Credential vault entry (if you store the PAT in one)
- [ ] Any IaC or automation that references the old credential
- [ ] Calendar reminder for next rotation
