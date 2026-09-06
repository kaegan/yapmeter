# Working on Yapmeter

Read `CONSTITUTION.md` before designing or building any feature, for the app
or for the website. It lists the boundaries a feature must not cross, the
product principles, and the two voice registers for copy. If a change adds a
permission, a network call, or a file on disk, the constitution is amended in
the same PR.

Build and test: `./scripts/build.sh` (see README). Tests are in
`YapmeterTests/` and the signal logic is pure and time-injected; keep it that
way.

## Backlog tickets

The backlog is the Notion database "Yapmeter backlog"; tickets are `YAP-n`.
When asked to plan or work on one ("plan YAP-12", "work on YAP-12", "plan
everything in Next Up", "revise YAP-12"), invoke the `yap` skill in
`.claude/skills/yap/`. It defines the status transitions, the branch and PR
conventions, and the rule that nothing is built from a ticket without a
`## Plan` in its page body.

## Releases

When asked to release ("release", "ship v0.2.3", "cut a release"), invoke
the `release` skill in `.claude/skills/release/`. A release is a tag on the
app repo plus a version bump on the site repo, in that order, and the skill
is the only place that order is written down.
