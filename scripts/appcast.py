#!/usr/bin/env python3
"""Add a release to Yapmeter's Sparkle appcast.

Sparkle ships a `generate_appcast` that infers the feed from a directory of
archives, which means the directory has to hold every archive you have ever
shipped or older entries quietly vanish. Releases here live on GitHub, not in
a directory, so this builds the feed the explicit way instead: read the
current appcast, prepend one item, keep the newest few, write it back.

The EdDSA signature is *not* computed here — it comes from Sparkle's own
`sign_update`, and is passed in. Nothing in this file touches key material.

Usage:
    appcast.py --appcast appcast.xml \\
        --version 0.2.0 --build 42 \\
        --url https://.../Yapmeter-0.2.0.zip \\
        --length 4194304 --signature <ed-signature> \\
        --notes-file notes.md
"""

import argparse
import html
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
KEEP_ITEMS = 10
MINIMUM_SYSTEM_VERSION = "14.2"

ET.register_namespace("sparkle", SPARKLE_NS)


def markdown_to_html(text):
    """A deliberately small subset: headings, `- ` bullets and paragraphs.

    Sparkle renders this in a WebView a few hundred points wide, and release
    notes for a menu bar app are a heading and a list of lines. Anything
    fancier than that is better off as a link than as a parser.
    """
    blocks = []
    bullets = []

    def flush_bullets():
        if bullets:
            blocks.append("<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    for raw in text.strip().splitlines():
        line = raw.strip()
        if not line:
            flush_bullets()
            continue
        escaped = html.escape(line)
        escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
        escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
        if line.startswith("- ") or line.startswith("* "):
            bullets.append(escaped[2:])
        elif line.startswith("#"):
            flush_bullets()
            level = min(len(line) - len(line.lstrip("#")), 3)
            blocks.append(f"<h{level}>{escaped.lstrip('# ')}</h{level}>")
        else:
            flush_bullets()
            blocks.append(f"<p>{escaped}</p>")
    flush_bullets()
    return "\n".join(blocks)


def read_items(path):
    """Existing items as dicts. A missing or empty feed is the first release."""
    if not path.exists() or not path.read_text().strip():
        return []
    channel = ET.parse(path).getroot().find("channel")
    if channel is None:
        return []
    items = []
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        items.append(
            {
                "title": (item.findtext("title") or "").strip(),
                "pub_date": (item.findtext("pubDate") or "").strip(),
                "description": (item.findtext("description") or "").strip(),
                "version": (item.findtext(f"{{{SPARKLE_NS}}}version") or "").strip(),
                "short_version": (
                    item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") or ""
                ).strip(),
                "minimum_system_version": (
                    item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion") or ""
                ).strip(),
                "url": enclosure.get("url", ""),
                "length": enclosure.get("length", ""),
                "signature": enclosure.get(f"{{{SPARKLE_NS}}}edSignature", ""),
            }
        )
    return items


def render(items):
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">',
        "    <channel>",
        "        <title>Yapmeter</title>",
        "        <link>https://yapmeter.com/appcast.xml</link>",
        "        <description>Updates to Yapmeter</description>",
        "        <language>en</language>",
    ]
    for item in items:
        lines += [
            "        <item>",
            f"            <title>{html.escape(item['title'])}</title>",
            f"            <pubDate>{item['pub_date']}</pubDate>",
            f"            <sparkle:version>{item['version']}</sparkle:version>",
            f"            <sparkle:shortVersionString>{item['short_version']}</sparkle:shortVersionString>",
            f"            <sparkle:minimumSystemVersion>{item['minimum_system_version']}</sparkle:minimumSystemVersion>",
            "            <description><![CDATA[",
            item["description"],
            "            ]]></description>",
            f'            <enclosure url="{html.escape(item["url"], quote=True)}"',
            f'                       length="{item["length"]}"',
            '                       type="application/octet-stream"',
            f'                       sparkle:edSignature="{html.escape(item["signature"], quote=True)}"/>',
            "        </item>",
        ]
    lines += ["    </channel>", "</rss>", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--version", required=True, help="marketing version, e.g. 0.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion, must increase")
    parser.add_argument("--url", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--minimum-system-version", default=MINIMUM_SYSTEM_VERSION)
    args = parser.parse_args()

    notes = args.notes_file.read_text() if args.notes_file else ""
    new_item = {
        "title": args.version,
        "pub_date": datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000"),
        "description": markdown_to_html(notes) if notes.strip() else "",
        "version": args.build,
        "short_version": args.version,
        "minimum_system_version": args.minimum_system_version,
        "url": args.url,
        "length": args.length,
        "signature": args.signature,
    }

    # Re-releasing a build replaces its entry rather than shipping two items
    # with the same sparkle:version, which Sparkle would treat as ambiguous.
    items = [i for i in read_items(args.appcast) if i["version"] != args.build]
    items.insert(0, new_item)
    items.sort(key=lambda i: int(i["version"] or 0), reverse=True)

    args.appcast.write_text(render(items[:KEEP_ITEMS]))
    print(f"Wrote {args.appcast} with {len(items[:KEEP_ITEMS])} item(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
