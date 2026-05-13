# Rollout Strategy

How to take a working PR gate from "one POC repo" to "enforced across the org" without burning down developer trust.

## The principle: phase it

A PR gate going from off to fully enforcing on day one is a great way to get every developer in the org filing complaints. The same gate, rolled out in phases over 2-3 months, is largely uncontroversial.

The phases:

```
Phase 0: POC          (1 repo, 1 week)
   ↓
Phase 1: Pilot        (3-5 repos, 2-4 weeks, warn-only)
   ↓
Phase 2: Enforce-soft (pilot repos, 30 days, hard-fail Critical only)
   ↓
Phase 3: Enforce-std  (pilot repos, 30 days, hard-fail High+)
   ↓
Phase 4: Expand       (next wave of repos, restart phase 1)
```

Each phase has clear success criteria and a clear "go/no-go" gate before the next phase.

## Phase 0: POC (1 week)

**Goal:** prove the technical setup works end-to-end on one repo with a cooperative owner.

**Activities:**
- Onboard 1 repo to Prisma Cloud
- Configure exception rule with full lockdown (Hard Fail Low+ across categories)
- Set up branch policy with reviewer requirement and Prisma as required status check
- Run two test PRs: clean (passes) and dirty (fake AWS key, fails)
- Capture screenshots as evidence

**Success criteria:**
- Clean test PR passes
- Dirty test PR fails and merge is blocked
- End-to-end timing measured (PR open → status check → merge decision: under 5 min)

**Output:**
- Demo evidence package (screenshots, timeline, configuration record)
- Lessons learned doc (what surprised you, what was harder than expected)
- Recommendation for whether to proceed to pilot

**Don't do in Phase 0:**
- Multiple repos (one is enough to prove the setup)
- Production-critical repos (use a less critical pilot for risk reduction)
- Strict thresholds for actual day-to-day (the lockdown is for the test demo only)

## Phase 1: Pilot warn-only (2-4 weeks)

**Goal:** generate real findings data on a representative set of repos without affecting day-to-day work.

**Configuration:**
- All severity thresholds at **Soft Fail** for Hard Fail position
- Comments Bot enabled at HIGH+ for visibility
- ADO branch policy still requires Prisma as a status check, but soft fails don't block

**Pick 3-5 pilot repos that span:**
- Different stacks (e.g., one .NET, one Node, one Python, one IaC-heavy)
- Different ages (newer repos vs legacy)
- Different sizes (small focused repos vs sprawling ones)
- Different team owners (don't pilot only one team's repos)
- A mix of "active development" and "stable maintenance"

**Activities:**
- Onboard pilot repos
- Configure warn-only enforcement
- Communicate to repo owners: "scanning is starting, no PRs will be blocked yet"
- Weekly triage sessions with each owner
- Track findings: new vs existing, severity distribution, fix rate, false positive rate

**Success criteria:**
- 4+ weeks of finding data collected
- False positive rate under ~30% per category
- At least one finding per pilot repo has been triaged to resolution (fix, suppress, or accept)
- No major operational issues (broken webhooks, scan timeouts, etc.)

**What you're learning:**
- What kinds of findings are common in your codebase
- Which severity thresholds are realistic
- Which categories have high false-positive rates
- Whether the team has triage capacity

**Don't do in Phase 1:**
- Hard fail anything (this is warn-only)
- Tighten thresholds during the pilot (lock the config and observe)
- Onboard more repos mid-pilot (let the data settle)

## Phase 2: Enforce on Critical only (30 days)

**Goal:** start blocking PRs, but only on the most severe findings, where everyone agrees blocking is right.

**Configuration:**
- Hard Fail at Critical for Vulnerabilities, Licenses
- Hard Fail at Low for Secrets (any secret is a problem)
- Hard Fail at High for IaC (misconfigurations are usually fixable)
- Soft Fail at High+ for Vulnerabilities and Licenses (visible warning, doesn't block)

**Communication to teams:**
- "Starting [date], PRs with new Critical findings will be blocked"
- "Existing findings on your branches won't fail PRs unless your PR introduces them"
- "Bypass process: contact [security lead] for emergency override"

**Activities:**
- Flip the threshold settings on pilot repos
- Track: how many PRs hit the gate, how many were true positives, how many bypass requests came in
- 1:1s with developers who hit the gate (collect feedback on dev experience)
- Weekly review of metrics with leadership

**Success criteria:**
- Blocked PRs are predominantly true positives (>80%)
- Bypass requests are infrequent (<5% of all PRs)
- No critical incident attributable to the gate (e.g., emergency hotfix blocked unnecessarily)
- Developer sentiment is "annoying but reasonable" not "this is broken"

**Don't do in Phase 2:**
- Tighten thresholds (give the team time to adjust before changing the rules)
- Add more repos (focus on getting pilot repos to steady state first)
- Skip the metrics tracking (this is your evidence for next phase)

## Phase 3: Enforce on High+ (30 days)

**Goal:** standard enforcement level for steady-state operation.

**Configuration:**
- Hard Fail at High for Vulnerabilities, Licenses, IaC
- Hard Fail at Low for Secrets
- Soft Fail at Medium+
- Comments Bot at Low+

**Activities:**
- Flip thresholds on pilot repos
- Continue weekly metrics review
- Document threshold decision with data ("based on 30 days at Critical-only, observed X true positives, Y bypass requests, decision is to tighten to High+")

**Success criteria:**
- Same as Phase 2: high TP rate, low bypass rate, no critical incidents
- Pilot repos are now in stable enforcement state
- Evidence package supports rollout to next wave of repos

**This is the steady state for most repos.** Some critical repos may go further (Pattern C in [enforcement rules](./03-enforcement-rules.md)), but Phase 3 is the standard.

## Phase 4: Expand to next wave

**Goal:** roll out to additional repos, restart the phase clock.

**Process:**
- Identify next 5-15 repos based on criticality
- Onboard them all in warn-only (Phase 1 for the new wave)
- Run the warn-only → Critical → High+ progression on a 60-day clock
- Pilot repos remain at Phase 3 throughout

**Don't shortcut:**
- New repos still need warn-only first, even if pilot repos already proved the setup
- Each wave's threshold tightening should be data-driven, not just calendar-driven
- If a new wave's repos are very different (different stack, different team), expect different findings patterns

## Phase 5: Org-wide

After multiple waves are at Phase 3, you've hit org-wide enforcement. At this point:

- New repos onboard with warn-only as default, escalate over time
- Threshold standards are documented, predictable, applied consistently
- Branch policy as code (managed via API/automation, not manual UI)
- Quarterly reviews at the org level to evaluate threshold adjustments

## What the metrics should show

By the end of rollout, you should have data on:

| Metric | Target |
|--------|--------|
| Onboarded repos | All target repos |
| Average days to merge a PR | Should be unchanged from baseline (gate doesn't slow normal work) |
| % PRs that hit the gate | <10% steady state |
| True positive rate of blocked PRs | >80% |
| Bypass requests per month | <5% of PRs |
| Findings introduced and caught at PR | Trending down (gate is shifting work earlier) |
| Mean time to fix critical findings | Trending down |

If any of these metrics are off, that's signal to revisit thresholds, communication, or rollout pacing.

## Communication patterns that work

**Before any change:**
- 1-2 weeks notice to affected teams
- Clear description of what's changing and why
- Explicit "what to do if you hit the gate" instructions
- Named contact for questions

**During rollout:**
- Weekly status updates (one paragraph) to leadership
- Office hours or Slack channel for developer questions
- Acknowledge friction publicly: "we know this is new, here's how to deal with it"

**After phase completion:**
- Metrics report
- Lessons learned
- Recommendation for next phase

## Communication patterns that don't work

- "We're turning on a security gate next Monday." Not enough notice, not enough context.
- "It's for compliance" with no further explanation. Compliance is everyone's least favorite reason.
- Quietly tightening thresholds without telling anyone. Trust killer.
- Punitive framing ("developers were ignoring findings"). Even when true, this poisons the working relationship.

## When to slow down

Stop and reassess if:

- Bypass requests exceed 10% of PRs (gate is causing real problems)
- True positive rate drops below 50% (gate is generating noise)
- Multiple teams escalate complaints in the same week (signal of broader issue)
- A bypass causes a real incident (revisit override process)

Pausing rollout to fix issues is far better than pushing through and losing trust. The gate isn't going anywhere — there's no benefit to rushing.
