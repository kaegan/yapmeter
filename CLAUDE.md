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

The backlog is the Notion database "Yapmeter backlog"; tickets are `YB-n`.
When asked to plan or work on one ("plan YB-12", "work on YB-12", "plan
everything in Next Up", "revise YB-12"), invoke the `yb` skill in `.claude/skills/yb/`. It
defines the status transitions, the branch and PR conventions, and the rule
that nothing is built from a ticket without a `## Plan` in its page body.
