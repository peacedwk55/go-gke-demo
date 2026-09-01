#!/usr/bin/env bash
#
# Wraps an Artifact fragment into a standalone HTML document for the repository.
#
# ─────────────────────────────────────────────────────────────────────────────
# Why this exists
# ─────────────────────────────────────────────────────────────────────────────
#
# The pages at the repository root are authored as Artifact *fragments*: no <!doctype>, no <html>, no
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
#   ./scripts/wrap-standalone-html.sh                 # re-wrap every root .html in place
#   ./scripts/wrap-standalone-html.sh SRC [OUT]      # wrap one fragment
#
# Both forms are idempotent: an existing wrapper is stripped before being
# re-applied, so running it twice changes nothing.

set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-}"
OUT="${2:-}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# With no arguments, re-wrap every standalone page in the repo root in place.
# Idempotent, so this is the safe thing to run after editing any of them.
if [ -z "$SRC" ]; then
    found=0
    for f in *.html; do
        [ -f "$f" ] || continue
        found=1
        "$0" "$f" "$f"
    done
    [ "$found" = 1 ] || { echo "error: no .html files in the repository root" >&2; exit 1; }
    exit 0
fi

# Output defaults to the source's own name, which is what makes an in-place
# re-wrap work.
[ -n "$OUT" ] || OUT="$(basename "$SRC")"

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
