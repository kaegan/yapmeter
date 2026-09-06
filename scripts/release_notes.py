#!/usr/bin/env python3
"""Write the release notes for a tag from the pull requests it ships.

GitHub's own `--generate-notes` lists every PR title verbatim with its author
and a link, which is a changelog for the developer, not release notes for the
person reading Sparkle's update dialog. This builds the notes the reader
wants instead: a "New features" list and a "Bug fixes" list, each line a PR
title with its `[YAP-n]` prefix stripped, and nothing else. Which list a PR
lands in comes from its label — `enhancement` or `bug` — and a PR with
neither (tooling, skills, CI, docs) is left out. If nothing qualifies the
notes say so in one line rather than shipping an empty dialog.

Usage:
    release_notes.py --repo kaegan/yapmeter --tag v0.2.0 > notes.md

The PR list comes from `gh`, so the token in the environment needs to read
pull requests. The range is `previous tag..tag` in git, so the checkout needs
its full history and tags.
"""

import argparse
import json
import re
import subprocess
import sys

FEATURE_LABEL = "enhancement"
BUG_LABEL = "bug"
# Both prefixes: the backlog was renamed from YB to YAP, and a release can
# span PRs merged under either one.
TICKET_PREFIX = re.compile(r"^\s*\[(?:YAP|YB)-\d+\]\s*")
FALLBACK = "Small fixes and improvements under the hood."


def clean_title(title):
    """`[YAP-42] fix the thing` -> `Fix the thing`."""
    title = TICKET_PREFIX.sub("", title).strip().rstrip(".")
    return title[:1].upper() + title[1:] if title else title


def format_notes(prs):
    """Markdown for a list of {"title", "labels"} dicts. Pure, so it can be
    exercised without a network: labels is a list of label names."""
    features = [clean_title(p["title"]) for p in prs if FEATURE_LABEL in p["labels"]]
    fixes = [
        clean_title(p["title"])
        for p in prs
        if BUG_LABEL in p["labels"] and FEATURE_LABEL not in p["labels"]
    ]
    sections = []
    if features:
        sections.append("## New features\n\n" + "\n".join(f"- {t}" for t in features))
    if fixes:
        sections.append("## Bug fixes\n\n" + "\n".join(f"- {t}" for t in fixes))
    return ("\n\n".join(sections) if sections else FALLBACK) + "\n"


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def previous_tag(tag):
    """The nearest v* tag before `tag`, or None for the first release."""
    try:
        return run("git", "describe", "--tags", "--abbrev=0", "--match", "v*", f"{tag}^").strip()
    except subprocess.CalledProcessError:
        return None


def shipped_prs(repo, tag):
    """PRs whose merge commit is reachable from `tag` but not from the tag
    before it. Matching on the merge commit rather than the merge date keeps
    a PR merged after the tag was cut out of this release's notes."""
    previous = previous_tag(tag)
    commits = set(run("git", "rev-list", f"{previous}..{tag}" if previous else tag).split())
    search = "base:main"
    if previous:
        since = run("git", "log", "-1", "--format=%cI", previous).strip()
        search += f" merged:>={since}"
    merged = json.loads(
        run(
            "gh", "pr", "list", "--repo", repo, "--state", "merged", "--limit", "500",
            "--search", search, "--json", "number,title,labels,mergeCommit",
        )
    )
    prs = [
        {"number": p["number"], "title": p["title"], "labels": [l["name"] for l in p["labels"]]}
        for p in merged
        if p.get("mergeCommit") and p["mergeCommit"]["oid"] in commits
    ]
    return sorted(prs, key=lambda p: p["number"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--tag", required=True, help="the tag being released, e.g. v0.2.0")
    args = parser.parse_args()

    prs = shipped_prs(args.repo, args.tag)
    print(f"{len(prs)} PR(s) in {args.tag}:", file=sys.stderr)
    for p in prs:
        print(f"  #{p['number']} {p['title']} {p['labels']}", file=sys.stderr)
    sys.stdout.write(format_notes(prs))


if __name__ == "__main__":
    main()
