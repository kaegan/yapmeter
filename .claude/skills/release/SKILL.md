---
name: release
description: Ship a public Yapmeter release end to end - tag the app, watch the Release workflow, check the release and the appcast, then bump the version on yapmeter.com through a PR and confirm the live site. Use when Kaegan says "release", "cut a release", "ship v0.2.3", "push a new version", "release the app", or "/release" (optionally with a version or "minor"/"major").
---

# Release: ship a version to people

A release is two repos and one order of operations. The app side is a tag:
`.github/workflows/release.yml` builds, notarizes, signs for Sparkle, writes
the release notes and republishes the appcast, and installed copies pick
the update up from `yapmeter.com/appcast.xml` on their next check. The site
side is a one-line version string in `kaegan/yapmeter-site` that nothing
updates for you, plus any site change that depends on a new release asset.
This skill does both, in that order, and stops at the first thing that is
wrong.

Kaegan is in the loop twice: he asks for the release, and he can say which
version if the default is wrong. Everything else runs to the end and reports.
Do not ask him to confirm steps he has already asked for.

Both repos are on this Mac: the app at the current working directory (a
checkout of `kaegan/yapmeter`) and the site at `~/Claude/yapmeter-site`.

## 1. Preflight

All of these, before anything is pushed. Say which one failed and stop;
do not fix it silently.

```bash
git fetch origin --tags
git status --short --branch
git rev-parse main origin/main
gh auth status
git tag --sort=-v:refname | head -3
```

- The tag is cut from `origin/main`, so `main` must equal `origin/main`.
  If this session is on a feature branch, that is fine: tag the commit
  `origin/main` points at, never `HEAD`.
- The tree must be clean. Uncommitted work is not in the release either
  way, but a dirty tree usually means a session is mid-task.
- `gh` must be signed in; the watch and the site PR need it.
- The site checkout must be clean and on `main`:
  `git -C ~/Claude/yapmeter-site status --short --branch`.

Then list what the release ships and decide the version:

```bash
LAST=$(git tag --sort=-v:refname | head -1)
git log --oneline "$LAST"..origin/main
gh pr list --state merged --limit 20 --json number,title,labels,mergedAt \
  --jq '.[] | "\(.number) [\(.labels|map(.name)|join(","))] \(.title)"'
```

- Nothing since the last tag: say so and stop. There is nothing to ship.
- Version: bump the patch number by default. Bump minor if Kaegan said
  "minor" or if the log carries something a user would call a new feature
  rather than a fix (a new menu item, a new permission, a changed minimum
  OS). Bump major only when he says so. Never re-use a tag.
- Say in chat what the release notes will contain: the `enhancement` and
  `bug` labelled PRs since the last tag, by title, the way
  `scripts/release_notes.py` will render them. If a PR that should be in
  the notes is unlabelled, label it now (`gh pr edit N --add-label
  enhancement`); the notes are generated from labels at build time, so
  this is the last moment it can be fixed.
- A merged PR that changed what the site should say (a new minimum OS, a
  new asset name like the disk image, copy that quotes app behaviour) is a
  site change for step 5. Note it now.

## 2. Tag and push

```bash
git tag vX.Y.Z origin/main && git push origin vX.Y.Z
```

The tag is the only place the marketing version is written; the build
number is the commit count. Nothing in `project.yml` or `Info.plist` is
edited for a release.

## 3. Watch the build

```bash
sleep 10 && gh run list --workflow release.yml --limit 1 --json databaseId,status,headBranch
gh run watch <id> --exit-status --interval 30
```

Run the watch in the background; the job takes 20 to 45 minutes, most of
it at Apple's notary. Use the time to prepare step 5 locally, but push
nothing to the site until step 4 passes.

If the run fails: `gh run view <id> --log-failed`, report the failing step
and its last lines, and stop. Do not delete the tag and do not touch the
site. A failed release is fixed by a PR to `main` and a new patch tag; the
failed tag stays as the record. The README's "Releasing" section lists
what each preflight step in the workflow is guarding against.

## 4. Verify the release

Both must pass before the site changes.

```bash
gh release view vX.Y.Z --json assets --jq '.assets[].name'
curl -fsSL https://yapmeter.com/appcast.xml | grep -o 'sparkle:shortVersionString="[^"]*"' | head -3
```

- Assets: `Yapmeter.dmg`, `Yapmeter.zip`, `appcast.xml`. All three, fixed
  names, no version in them.
- The appcast served from yapmeter.com names the new version. That line is
  proxied by the site's Vercel rewrite from GitHub's latest release, so it
  proves both that the feed was rebuilt and that the rewrite is alive. If
  the feed lists only the new version and nothing older, the workflow could
  not fetch the previous feed and rebuilt from scratch; say so, because
  the history is lost even though updates still work.

## 5. Site

In `~/Claude/yapmeter-site`, from a fresh `main`:

```bash
git -C ~/Claude/yapmeter-site fetch origin main
git -C ~/Claude/yapmeter-site checkout -b claude/release-vX.Y.Z origin/main
```

- Set `CURRENT_VERSION` in `src/main.js` to `vX.Y.Z`. That string is what
  the download button shows; the link next to it is
  `releases/latest/download/Yapmeter.dmg` and never changes.
- Apply any site change noted in step 1. A change that references a new
  release asset or new behaviour lands here, after the release, never
  before it: a link to an asset that does not exist yet is a 404 on the
  home page.
- Commit, push, open the PR (`Show vX.Y.Z on the download button`), with
  `ref YAP-n` for the release's ticket if there is one. Merge it with a
  merge commit. Vercel deploys `main` on push; wait for it:

```bash
until curl -fsSL https://yapmeter.com | grep -q "vX.Y.Z"; do sleep 20; done
```

The version is written into the page by `src/main.js` at load, not in the
HTML, so grep the built bundle if the page itself does not carry it:
`curl -fsSL https://yapmeter.com/assets/$(curl -fsSL https://yapmeter.com | grep -o 'index-[^"]*\.js')`.

Delete the branch after the merge.

## 6. Report

One message: the release URL, the version, the notes as they will appear
in the update dialog, and the site URL. Mention what the user of an
installed copy will see: Sparkle offers the update on its next scheduled
check, or straight away from "Check for Updates…" in the menu. If the
release included a change to the app's minimum OS, say which installed
copies will not be offered it.

## Things that went wrong before

- **The site was forgotten.** v0.1.3, v0.2.0, v0.2.1 and v0.2.2 all shipped
  with the site still saying v0.1.2 (YAP-75). That is why step 5 is in
  this skill and not in a README sentence.
- **The site link pointed at an asset the release did not have yet.** The
  disk image arrived in v0.2.3 (YB-57); the site could only switch its
  link from the zip to the dmg after that release existed. Hence "after,
  never before" in step 5.
- **A release with no labelled PRs** says "Small fixes and improvements" in
  the update dialog. Check the labels in step 1 while they can still be
  changed.
