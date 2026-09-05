# Working on Yapmeter

Read `CONSTITUTION.md` before designing or building any feature, for the app
or for the website. It lists the boundaries a feature must not cross, the
product principles, and the two voice registers for copy. If a change adds a
permission, a network call, or a file on disk, the constitution is amended in
the same PR.

Build and test: `./scripts/build.sh` (see README). Tests are in
`YapmeterTests/` and the signal logic is pure and time-injected; keep it that
way.
