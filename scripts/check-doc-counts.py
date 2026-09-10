"""Verify every '<em>N บรรทัด</em>' in repo-guide.html against the real file.

Why this is a gate and not a chore. repo-guide.html documents the repository
file by file and states each file's length. Twenty-three of those numbers were
wrong at the same time, having drifted quietly across several sessions, and the
page reads as authoritative either way. Hardcoded counts in this repository have
gone stale repeatedly; a reader cannot tell a current number from a stale one, so
the number is worse than no number unless something checks it.

Run with --apply to rewrite the stale numbers. Without it the script reports and
exits non-zero if anything is wrong, which is how CI uses it.

Note the self-reference: the page lists its own length, so --apply can need two
passes to reach a fixed point. The caller loops.
"""

import io, os, re, subprocess, sys, collections

APPLY = "--apply" in sys.argv
p = "repo-guide.html"
s = io.open(p, encoding="utf-8").read()

tracked = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
by_base = collections.defaultdict(list)
for f in tracked:
    by_base[os.path.basename(f)].append(f)


def lines(path):
    with io.open(path, encoding="utf-8", errors="replace") as fh:
        return sum(1 for _ in fh)


# walk the document, remembering the most recent <h2> section as directory context
sections = [(m.start(), re.sub(r"<[^>]+>", "", m.group(1)).strip())
            for m in re.finditer(r"<h2>(.*?)</h2>", s, re.S)]


def section_for(pos):
    cur = ""
    for start, name in sections:
        if start < pos:
            cur = name
        else:
            break
    return cur.replace("/", "").strip()


# The page names four different files "tasks/main.yml" and eight "README.md",
# so basename resolution cannot work for those. Resolved by document order,
# each one checked against the role heading printed immediately above it.
OVERRIDES = {
    ("README.md", 0): "README.md",
    ("README.md", 4): "infra/terraform/README.md",
    ("tasks/main.yml", 0): "ansible/roles/common/tasks/main.yml",
    ("tasks/main.yml", 1): "ansible/roles/docker/tasks/main.yml",
    ("tasks/main.yml", 2): "ansible/roles/nginx_container/tasks/main.yml",
    ("tasks/main.yml", 3): "ansible/roles/node_exporter/tasks/main.yml",
}
seen = collections.Counter()

ok = bad = unresolved = 0
fixes = []

for m in re.finditer(r'<div class="f-name">([^<]+?)<em>(\d+) บรรทัด</em>', s):
    name, claimed = m.group(1).strip(), int(m.group(2))
    sec = section_for(m.start())

    idx = seen[name]
    seen[name] += 1
    if (name, idx) in OVERRIDES:
        cands = [OVERRIDES[(name, idx)]]
        assert cands[0] in tracked, "override points at a missing file: %s" % cands[0]
    else:
        cands = []
    if not cands and sec:
        guess = "%s/%s" % (sec, name)
        if guess in tracked:
            cands = [guess]
        else:
            cands = [f for f in tracked if f.endswith("/" + name) and f.startswith(sec.split("/")[0])]
    if not cands:
        cands = by_base.get(os.path.basename(name), [])
        if name.count("/"):
            cands = [f for f in tracked if f.endswith(name)]

    if len(cands) != 1:
        unresolved += 1
        print("  ?  %-40s section=%-22s candidates=%d" % (name, sec, len(cands)))
        continue

    real = lines(cands[0])
    if real == claimed:
        ok += 1
    else:
        bad += 1
        print("  X  %-40s doc=%-5s จริง=%-5s  (%s)" % (name, claimed, real, cands[0]))
        fixes.append((m.group(0), m.group(0).replace(
            "<em>%d บรรทัด</em>" % claimed, "<em>%d บรรทัด</em>" % real)))

print()
print("ตรง %d · ผิด %d · หาไฟล์ไม่ได้ %d" % (ok, bad, unresolved))

if APPLY and fixes:
    for old, new in fixes:
        assert s.count(old) == 1, "not unique: %s" % old
        s = s.replace(old, new, 1)
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)
    print("rewrote %d stale counts" % len(fixes))
    sys.exit(0)

# An unresolved entry is a failure too, not a shrug: it means the page names a
# file this script cannot find, so either the name is wrong or the resolver is.
sys.exit(1 if (bad or unresolved) else 0)
