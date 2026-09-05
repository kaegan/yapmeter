---
name: yb
description: Plan or build one Yapmeter backlog ticket (YB-n) from the Notion backlog. Use when Kaegan says "plan YB-12", "work on YB-12", "build YB-12", "plan everything in Next Up", or "/yb plan 12" / "/yb work 12".
---

# YB-n: plan a ticket, or build one

The Notion backlog is the source of truth for *what* to build. The ticket
page body is where the plan lives. GitHub holds the branch, the PR and CI.
Kaegan is in the loop at exactly two points: he approves the plan, and he
reviews the PR. Nothing in Notion triggers anything; a session only does
what he asked for in chat.

## Finding the ticket

The backlog data source is `collection://d0115c29-c2f0-4b88-bf5e-a8df40131280`.
`YB-12` is the row whose `userDefined:ID` is 12:

```sql
SELECT url, "Name", "Status", "Type", "Area", "Priority", "Notes", "Parent"
FROM "collection://d0115c29-c2f0-4b88-bf5e-a8df40131280"
WHERE "userDefined:ID" = 12
```

Then fetch the page URL for the body. Page bodies follow the ticket
template: `## Problem`, `## Acceptance Criteria`, `## Out of Scope`,
`## Notes`. If `Parent` is set, fetch the epic too; it usually carries the
context the sub-item leaves out.

Status values, in order: `Idea`, `Next Up`, `Planning`, `Building`,
`Reviewing`, `Done`, `Not doing`. Never hand-edit the `GitHub` relation;
Notion's GitHub integration fills it from the PR description.

Read `CONSTITUTION.md` before planning or building anything.

## `plan YB-n`

1. Set `Status` to `Planning`.
2. Read the ticket, its epic, and the code it touches. Do not build.
3. Write a `## Plan` section at the end of the page body (replace an
   existing one). Keep it under about thirty lines:
   - **Goal**: one or two sentences, in the ticket's own terms.
   - **Approach**: the files to touch and the steps, in order. Name the
     state or signal logic changes explicitly; that code is pure and
     time-injected and must stay that way.
   - **Tests**: what goes in `YapmeterTests/`.
   - **Out of scope**: anything the ticket hints at that this PR will not do.
   - **Constitution**: which boundary or principle it touches. If it adds a
     permission, a network call, or a file on disk, say that
     `CONSTITUTION.md` is amended in the same PR and what the amendment is.
   - **Open questions**: only ones that change the approach. Otherwise
     state the assumption and move on.
4. Leave `Status` at `Planning`. Report the plan in chat in a few lines and
   link the page. Kaegan reads it in Notion; he approves by saying
   "work on YB-n" or by moving the ticket to `Next Up`.

Bug tickets (`Type` = `Bug`): the plan is a diagnosis plus the fix. If the
bug can only be reproduced in a real meeting, say so in **Open questions**
rather than guessing.

`plan everything in Next Up` (or `plan Next Up`): query `Status` = `Next Up`,
skip rows whose body already has a `## Plan`, run the steps above for each,
and finish with one summary listing every ticket and its one-line goal.

## `work on YB-n`

1. The page body must have a `## Plan`. If it does not, run `plan YB-n`
   and stop; do not build from an unplanned ticket.
2. Set `Status` to `Building`.
3. Branch from a fresh `main`:
   ```bash
   git fetch origin main && git checkout -b claude/yb-12-short-slug origin/main
   ```
4. Implement the plan. If the plan turns out to be wrong, update the
   `## Plan` section to say what changed and why, then carry on; only stop
   if the change would alter what Kaegan approved.
5. Verify. `./scripts/build.sh` builds, installs and launches the app.
   Run the tests the way CI does:
   ```bash
   xcodegen generate && xcodebuild test -project Yapmeter.xcodeproj -scheme Yapmeter -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
   ```
6. Commit, push, and open the PR:
   - Title: `[YB-12] <ticket name>`.
   - Body: a **What** and a **Why** paragraph, then a line reading
     `close YB-12` on its own (use `ref YB-12` if the PR does not finish
     the ticket). CI fails a PR without that line, and it is what links
     the PR to the Notion row.
   - End the body with the Claude Code attribution footer.
7. Set `Status` to `Reviewing`. Report the PR link and anything the plan
   left open. Do not merge unless Kaegan says to.
8. When Kaegan says merge (or has merged it himself): merge with a merge
   commit, set `Status` to `Done`, and delete the branch.

## Things that were tried and rejected

Do not add a Notion webhook, a routine, a scheduled task, or a cloud
dispatcher to trigger any of this. Kaegan built that on 2026-09-05 and tore
it out: runs were invisible, permission prompts piled up, and cloud sessions
cannot build the Mac app. Typing "work on YB-n" in a desktop session is the
whole trigger.
