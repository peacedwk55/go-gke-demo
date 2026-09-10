# `.zap/` — DAST policy

One file, `rules.tsv`, which decides what a ZAP finding does to the build. The
reasoning per rule is in that file's comments, next to the rule it argues about.
This README covers the two decisions above it: whether to run DAST here at all,
and which ZAP scan to run.

## Why there is a DAST gate at all

The app reflects `?name=` into the response body without escaping it. That is
safe — and only safe — because every response carries both
`Content-Type: text/plain; charset=utf-8` and `X-Content-Type-Options: nosniff`.
Drop the second header and a browser may sniff the body as HTML, at which point
the reflection is XSS. CLAUDE.md §1.1 requires the pair for exactly this reason.

Three checks now cover that pair, and they fail for different reasons:

| Check | Reads | Would miss |
|---|---|---|
| `TestHelloIsNotHTML` | the handler's own `ResponseRecorder` | anything that strips the header after the handler returns |
| `gosec` G705 | the source | a header removed elsewhere; a proxy rewriting responses |
| **ZAP baseline** | **HTTP off the wire, from outside the process** | a flaw with no HTTP signature |

Only the third sees the header actually arrive. That is the whole argument for
adding it: it is the only gate in the pipeline that tests the running binary
rather than a description of it.

## Proof the gate works — both directions

A gate that has only ever been observed passing is not known to work. So before
this was committed, the app was copied, both headers deleted from
`writePlain`, and the copy scanned alongside the real image.

```
hardened build         FAIL-NEW: 0   WARN-NEW: 2   PASS: 65   exit 0
X-Content-Type-Options
  removed              FAIL-NEW: 1   WARN-NEW: 2   PASS: 64   exit 1
```

Exactly one line differed, and it was the right one:

```
FAIL-NEW: X-Content-Type-Options Header Missing [10021] x 1
```

Measured 2026-09-10, ZAP 2.17.0, against `go-sample-app` built from this
repository. The vulnerable copy lived outside the working tree and was deleted
afterwards; nothing in Git has ever been missing those headers.

Worth noting what the vulnerable build still did: it returned
`Content-Type: text/plain` regardless, because Go's MIME sniffer does not see
`Hello <script>…` as HTML — the `Hello ` prefix defeats it. So the reflection is
not exploitable in a modern browser even without `nosniff`, and ZAP reports the
missing header rather than an XSS. The header is defence in depth, and the gate
protects the header. Both statements are narrower than "ZAP catches the XSS",
and both are true.

## baseline, not full-scan — also measured

`zap-full-scan.py` adds active attack traffic on top of the passive rules.
Run against this app it took **8 minutes over 140 rules and reported nothing the
2.5-minute passive baseline had not already found** — one alert, the same
`Cross-Origin-Resource-Policy` warning.

That is not a surprise on reflection: four endpoints, all `text/plain`, no forms,
no cookies, no session, no database. An active scanner has almost nothing to work
with. So CI runs the baseline, and the full scan is a manual tool:

```bash
# start the image under test on a bridge the scanner can reach
docker network create dast
docker run -d --name dast-target --network dast go-sample-app:<tag>

# ~8 minutes; writes reports into the mounted directory
mkdir -p zap-out && chmod 777 zap-out
cp .zap/rules.tsv zap-out/rules.tsv
docker run --rm --network dast -v "$PWD/zap-out:/zap/wrk:rw" \
  zaproxy/zap-stable:2.17.0 \
  zap-full-scan.py -t http://dast-target:8080 -c rules.tsv -I -m 2 \
  -r zap-report.html -w zap-report.md -J zap-report.json

docker rm -f dast-target && docker network rm dast
```

This is worth re-running whenever the app gains surface an active scanner can
push on — a form, a cookie, a redirect, a second content type. The measurement
above is a fact about today's four handlers, not a permanent property.

## Two things that cost time, written down

**The image name.** Nearly every DAST tutorial says `owasp/zap2docker-stable`.
That image was retired; pulling it now fails with `object not found`. The current
one is `zaproxy/zap-stable`.

**`chmod 777` on the output directory, and it is not sloppiness.** ZAP runs as
uid 1000 (`zap`) inside its image. A GitHub Actions workspace belongs to uid 1001
(`runner`), so ZAP cannot write its reports into a directory the job just
created — the scan runs, then the step fails on a file write for a reason that
has nothing to do with security. Docker Desktop's mounts are permissive and hide
this completely, so it is invisible until CI, which is why it is a comment in
`ci.yaml` as well as a paragraph here.
