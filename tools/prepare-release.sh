#!/usr/bin/env bash
# Prepare a release by bumping the app version and updating README
# links and history in one pass.
#
# Usage: tools/prepare-release.sh <new-version>
# Example: tools/prepare-release.sh 2.10.4
#
# The script:
#   - reads the current `version: X.Y.Z+N` line from pubspec.yaml
#   - sets it to `<new-version>+<N+1>`
#   - updates the two "latest release" links in README.md to point at
#     v<new-version>, and appends ` . <new-version>` to the history
#     list (which lives on a single line ending in `</b>`).
#
# The script deliberately does NOT commit, tag, or push — you review
# the diff first, then commit/tag/push yourself. It also refuses to
# run if the new version isn't strictly newer than the current one.

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  die "usage: $0 <new-version>   (e.g. 2.10.4)"
fi

NEW_VER=$1
if ! [[ "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "version must be X.Y.Z, got '$NEW_VER'"
fi

# Resolve repo root from the script's location so the script works
# regardless of where it's invoked from.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PUBSPEC="$REPO_ROOT/pubspec.yaml"
README="$REPO_ROOT/README.md"

[[ -f "$PUBSPEC" ]] || die "pubspec not found: $PUBSPEC"
[[ -f "$README" ]] || die "README not found: $README"

# Extract current version and build number.
CURRENT_LINE=$(grep -E '^version: [0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$' "$PUBSPEC" || true)
[[ -n "$CURRENT_LINE" ]] || die "could not find a 'version: X.Y.Z+N' line in $PUBSPEC"

CURRENT_VER=${CURRENT_LINE#version: }
CURRENT_SEMVER=${CURRENT_VER%+*}
CURRENT_BUILD=${CURRENT_VER##*+}

# Refuse to "bump" to the same or older version. Compare as tuples.
if [[ "$NEW_VER" == "$CURRENT_SEMVER" ]]; then
  die "new version ($NEW_VER) is the same as current ($CURRENT_SEMVER)"
fi
sort_check=$(printf '%s\n%s\n' "$CURRENT_SEMVER" "$NEW_VER" | sort -V | tail -n1)
if [[ "$sort_check" != "$NEW_VER" ]]; then
  die "new version ($NEW_VER) is older than current ($CURRENT_SEMVER)"
fi

NEW_BUILD=$((CURRENT_BUILD + 1))
NEW_FULL="$NEW_VER+$NEW_BUILD"

printf 'bumping %s → %s\n' "$CURRENT_VER" "$NEW_FULL"

# --- pubspec.yaml ---
# Use a precise match on the full current line so we never accidentally
# rewrite a similar-looking line elsewhere.
sed -i "s|^version: ${CURRENT_VER}\$|version: ${NEW_FULL}|" "$PUBSPEC"
grep -q "^version: ${NEW_FULL}\$" "$PUBSPEC" || die "pubspec rewrite failed"

# --- README.md ---
# Three edits, all keyed off the previous semver. We match the
# concrete link substring `tag/v<CURRENT_SEMVER>` rather than a looser
# pattern so we only touch links that actually pointed to the last
# released version.
#
# 1. The release badge link near the top of the file.
# 2. The "Latest Release" paragraph just above the Resources block.
# 3. The history line that lists every past release separated by ` . `.
#
# Edits 1 and 2 are the same `tag/v<CURRENT>` → `tag/v<NEW>` substitution
# (plus, for #2, the visible `<CURRENT>` label inside the anchor).
# Edit 3 appends to the list by inserting `<NEW>` immediately after the
# last existing entry (which is `<CURRENT>` wrapped in an anchor and
# followed by `</b>`).
#
# Do all three with sed in-place, one pattern at a time.

# Safety check: both the current version's link and label should appear.
grep -q "tag/v${CURRENT_SEMVER}" "$README" \
  || die "README doesn't mention tag/v${CURRENT_SEMVER} — already updated?"

# Edits 1 + 2 (rewrite every `tag/v<CURRENT>` link to point at NEW, and
# every `>CURRENT<` visible label inside anchors too). This rewrites
# the history entry for the current version as well, which we then
# restore by re-appending the old label in edit 3 below.
sed -i "s|tag/v${CURRENT_SEMVER}|tag/v${NEW_VER}|g" "$README"
sed -i "s|>${CURRENT_SEMVER}</a>|>${NEW_VER}</a>|g" "$README"

# Edit 3: we've overwritten the old CURRENT → NEW everywhere. The
# history list now ends with `NEW` but has lost its `CURRENT` entry
# (there's now a duplicate `NEW` instead). Fix by replacing the final
# `. <NEW>` with `. <CURRENT> . <NEW>`.
#
# The history list is a single line that ends like:
#   . <a href="...tag/vNEW">NEW</a></b>
# After our sweep we need exactly one occurrence of:
#   . <a href="...tag/v${CURRENT_SEMVER}">${CURRENT_SEMVER}</a>
# inserted before the final entry.
python3 - "$README" "$CURRENT_SEMVER" "$NEW_VER" <<'PY'
import re
import sys

readme_path, current, new_ver = sys.argv[1], sys.argv[2], sys.argv[3]
with open(readme_path, encoding="utf-8") as f:
    text = f.read()

new_entry = (
    f' .\n  <a href="https://github.com/ShiroiKuma0/jidoujisho2'
    f'/releases/tag/v{new_ver}">{new_ver}</a>'
)
current_entry = (
    f'  <a href="https://github.com/ShiroiKuma0/jidoujisho2'
    f'/releases/tag/v{current}">{current}</a>'
)

# Find the last `. <a ...>NEW</a></b>` in the history line and
# insert a `. CURRENT` entry before it if it's missing.
history_final_pattern = re.compile(
    r'(  <a href="https://github\.com/ShiroiKuma0/jidoujisho2'
    r'/releases/tag/v' + re.escape(new_ver) + r'">' +
    re.escape(new_ver) + r'</a></b>)'
)
if f'tag/v{current}' not in text:
    # CURRENT link was removed by the sed sweep — reinsert before the
    # final NEW entry.
    def repl(m):
        return f'{current_entry} .\n{m.group(1)}'
    text, n = history_final_pattern.subn(repl, text, count=1)
    if n != 1:
        sys.exit('error: could not restore current-version history entry')

with open(readme_path, 'w', encoding="utf-8") as f:
    f.write(text)
PY

printf '\ndiff:\n'
git -C "$REPO_ROOT" diff -- "$PUBSPEC" "$README" | head -80

printf '\nNext steps:\n'
printf '  1. Review the diff above (run `git diff` for the full view).\n'
printf '  2. Build and install to verify everything still works.\n'
printf '  3. git add -A && git commit -m "Release %s" && git tag -a v%s -m "Release %s" && git push origin main && git push origin v%s\n' \
  "$NEW_VER" "$NEW_VER" "$NEW_VER" "$NEW_VER"
