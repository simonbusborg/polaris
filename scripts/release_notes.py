#!/usr/bin/env python3
"""Write the release notes page Sparkle shows inside its update panel.

Pointing sparkle:releaseNotesLink at a GitHub release renders the whole
site — nav bar, sign-in button and all — inside a 500pt box. This writes a
small standalone page to docs/notes/<tag>.html instead, served from the
same GitHub Pages site as the appcast.

The notes are the commit subjects since the previous tag, which is why
those subjects are written as sentences about intent.

    release_notes.py <tag> [previous-tag]
"""
import html
import re
import subprocess
import sys
from pathlib import Path

tag = sys.argv[1]
version = tag[1:] if tag.startswith("v") else tag

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True,
                          check=True).stdout.strip()

if len(sys.argv) > 2:
    previous = sys.argv[2]
else:
    # The tag itself is already in the list, so the previous one is next.
    tags = git("tag", "--sort=-creatordate").splitlines()
    previous = tags[tags.index(tag) + 1] if tag in tags and len(tags) > tags.index(tag) + 1 else ""

span = f"{previous}..{tag}" if previous else tag
log = git("log", "--no-merges", "--pretty=%H\t%s", span).splitlines()

# Release plumbing is noise in a changelog: nobody upgrades to read that
# the cask was bumped.
noise = re.compile(r"^(Release v|Publish v.*appcast|Update the cask)")

# Nor does anyone upgrading the app care about the website or the CI
# workflow. A commit counts only if it touched something that ships
# inside the .app.
def ships(sha):
    files = git("show", "--name-only", "--pretty=", sha).splitlines()
    return any(not f.startswith(("docs/", ".github/", "Tests/", "scripts/"))
               and f not in ("README.md", "CONTRIBUTING.md", "ROADMAP.md")
               for f in files if f)

items = []
for line in log:
    sha, _, subject = line.partition("\t")
    if subject.strip() and not noise.match(subject) and ships(sha):
        items.append(subject)

date = git("log", "-1", "--format=%ad", "--date=format:%B %-d, %Y", tag)

body = "\n".join(f"      <li>{html.escape(i)}</li>" for i in items) or \
       "      <li>Maintenance and small fixes.</li>"
compare = (f"https://github.com/simonbusborg/polaris/compare/{previous}...{tag}"
           if previous else f"https://github.com/simonbusborg/polaris/releases/tag/{tag}")

page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Polaris {version}</title>
<style>
  /* Sparkle renders this in a small WebView that follows the system
     appearance, so the page has to work in both and stay legible at
     roughly 500 points wide. */
  :root {{ color-scheme: light dark; }}
  body {{
    margin: 0;
    padding: 18px 20px 22px;
    font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    color: #1d1d1f;
    background: #fff;
  }}
  h1 {{ margin: 0; font-size: 17px; letter-spacing: -0.01em; }}
  .date {{ margin: 2px 0 16px; font-size: 12px; color: #6e6e73; }}
  ul {{ margin: 0; padding-left: 18px; }}
  li {{ margin-bottom: 7px; }}
  a {{ color: #0a6cff; text-decoration: none; }}
  a:hover {{ text-decoration: underline; }}
  footer {{ margin-top: 18px; font-size: 12px; color: #6e6e73; }}
  @media (prefers-color-scheme: dark) {{
    body {{ color: #f2f2f7; background: #1e1e1e; }}
    .date, footer {{ color: #9a9aa0; }}
    a {{ color: #6cb1ff; }}
  }}
</style>
</head>
<body>
  <h1>Polaris {version}</h1>
  <p class="date">{date}</p>
  <ul>
{body}
  </ul>
  <footer><a href="{compare}">All changes on GitHub</a></footer>
</body>
</html>
"""

path = Path("docs/notes") / f"{tag}.html"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(page)
print(f"wrote {path} with {len(items)} entries")
