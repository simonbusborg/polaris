#!/usr/bin/env python3
"""Prepend a release to Sparkle's appcast.

Called from .github/workflows/release.yml with the signature attributes
sign_update produced for Polaris.zip. Kept out of the workflow because a
multi-line XML template inside a YAML block scalar is unreadable and
fragile.

    update_appcast.py <tag> <build> '<sparkle:edSignature="…" length="…">'
"""
import sys
from datetime import datetime, timezone

tag, build, attrs = sys.argv[1], sys.argv[2], sys.argv[3]
version = tag[1:] if tag.startswith("v") else tag
date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
base = "https://github.com/simonbusborg/polaris/releases"
# The notes page lives beside the appcast on Pages; linking the GitHub
# release instead renders the whole site inside Sparkle's panel.
notes = "https://simonbusborg.github.io/polaris"

item = f"""    <item>
      <title>{version}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{notes}/notes/{tag}.html</sparkle:releaseNotesLink>
      <enclosure url="{base}/download/{tag}/Polaris.zip"
                 type="application/octet-stream" {attrs} />
    </item>"""

path = "docs/appcast.xml"
feed = open(path).read()
marker = "    <!-- items -->"
if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" in feed:
    print(f"{version} is already in the appcast — nothing to do")
    sys.exit(0)
# Newest first: Sparkle picks the best candidate on its own, but a human
# reading the feed should meet the current release at the top.
open(path, "w").write(feed.replace(marker, marker + "\n" + item, 1))
print(f"added {version} to the appcast")
