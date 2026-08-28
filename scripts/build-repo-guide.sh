#!/usr/bin/env bash
#
# Wraps the artifact fragment into a standalone HTML document for the repository.
#
# ─────────────────────────────────────────────────────────────────────────────
# Why this exists
# ─────────────────────────────────────────────────────────────────────────────
#
# repo-guide.html is authored as a *fragment*: no <!doctype>, no <html>, no
# <head>. That is what the Artifact platform requires — it supplies the skeleton
# at publish time, which is why the published page renders correctly.
#
# Opened as a local file, that same fragment has no charset declaration. A
# browser then falls back to a legacy single-byte encoding and every Thai
# character renders as mojibake ("ไฟล์" -> "à¸„à¹Œ"). The bytes on disk were
# valid UTF-8 the whole time; only the declaration was missing.
#
# Two properties matter and are easy to get wrong:
#
#   1. <meta charset> must appear within the first 1024 bytes of the document.
#      Browsers stop looking after that, so it goes first — before <title>,
#      which contains the very Thai text that needs decoding.
#
#   2. The fragment and the standalone file must not drift. Hence generating one
#      from the other rather than maintaining both by hand.
#
# Usage:
#   ./scripts/build-repo-guide.sh <path-to-fragment>
#
# With no argument it re-wraps the repo copy in place, which is safe and
# idempotent: the wrapper is stripped before being re-applied.

set -euo pipefail

cd "$(dirname "$0")/.."

OUT="repo-guide.html"
SRC="${1:-}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [ -z "$SRC" ]; then
    if [ ! -f "$OUT" ]; then
        echo "error: no fragment given and $OUT does not exist" >&2
        exit 1
    fi
    SRC="$OUT"
fi

# Strip an existing wrapper if present, so re-running is idempotent.
#
# Four pieces have to come off, not two — which the first version of this script
# got wrong, duplicating </head> and <body> on every re-run:
#
#   1. everything before <title>          (doctype, <html>, <head>, the metas)
#   2. the </head> that closes it         <- missed first time round
#   3. the <body> that follows it         <- missed first time round
#   4. </body></html> at the very end
#
# `0,/re/` bounds each deletion to the FIRST match, so a stray </head> or <body>
# appearing later in the content could not be eaten by accident.
if grep -q '^<!doctype html>' "$SRC"; then
    sed -n '/^<title>/,$p' "$SRC" \
        | sed '/^<\/body>$/,$d' \
        | sed '0,/^<\/head>$/{/^<\/head>$/d}' \
        | sed '0,/^<body>$/{/^<body>$/d}' > "$TMP"
else
    cp "$SRC" "$TMP"
fi

# The fragment's head-bound content is everything up to and including </style>.
STYLE_END="$(grep -n '^</style>$' "$TMP" | head -1 | cut -d: -f1)"
if [ -z "$STYLE_END" ]; then
    echo "error: could not find the closing </style> that separates head from body" >&2
    exit 1
fi

{
    echo '<!doctype html>'
    echo '<html lang="th">'
    echo '<head>'
    # First, and deliberately so — see note 1 above.
    echo '<meta charset="utf-8">'
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">'
    # Tells the browser the page handles both themes, so form controls and
    # scrollbars match the palette instead of staying light.
    echo '<meta name="color-scheme" content="light dark">'
    echo '<meta name="description" content="อธิบายทุกโฟลเดอร์ทุกไฟล์ในรีโป Go-on-GKE พร้อมวงจรชีวิตของโปรเจกต์และแผนขั้นต่อไป">'
    head -n "$STYLE_END" "$TMP"
    echo '</head>'
    echo '<body>'
    tail -n +"$((STYLE_END + 1))" "$TMP"
    echo '</body>'
    echo '</html>'
} > "$OUT.new"

mv "$OUT.new" "$OUT"

# Verify the thing this script exists to guarantee, rather than assuming it.
if ! head -c 1024 "$OUT" | grep -q 'charset="utf-8"'; then
    echo "error: charset is not within the first 1024 bytes — browsers will ignore it" >&2
    exit 1
fi

echo "wrote $OUT"
echo "  charset declared in first 1024 bytes: yes"
echo "  lines: $(wc -l < "$OUT")"
