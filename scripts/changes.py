#!/usr/bin/env python3
"""Turn a diff from `pour registry build --diff` into the register/de-register
log: one JSON file per run under changes/ and the top of CHANGES.md.
Exit code 0 = nothing changed, 1 = something changed (so update.sh can tell)."""
import json, sys, os
diff_file, stamp, outdir, md = sys.argv[1:5]
d = json.load(open(diff_file))
total = sum(len(v) for k in ("formulae", "casks") for v in d.get(k, {}).values())
if total == 0:
    sys.exit(0)
os.makedirs(outdir, exist_ok=True)
name = stamp.replace(":", "").replace("-", "")[:15]
json.dump({"synced_at": stamp, **d}, open(os.path.join(outdir, f"{name}.json"), "w"), indent=1)
lines = [f"## {stamp}\n"]
for kind in ("formulae", "casks"):
    sec = d.get(kind, {})
    if sec.get("added"):
        lines.append(f"- **Registered {len(sec['added'])} {kind}**: " + ", ".join(f"`{x}`" for x in sec["added"][:40]) + (" …" if len(sec["added"]) > 40 else ""))
    if sec.get("removed"):
        lines.append(f"- **De-registered {len(sec['removed'])} {kind}**: " + ", ".join(f"`{x}`" for x in sec["removed"][:40]) + (" …" if len(sec["removed"]) > 40 else ""))
    if sec.get("updated"):
        ups = sec["updated"]
        lines.append(f"- Updated {len(ups)} {kind}: " + ", ".join(f"`{u['name']}` {u['from']} → {u['to']}" for u in ups[:25]) + (" …" if len(ups) > 25 else ""))
entry = "\n".join(lines) + "\n\n"
old = ""
if os.path.exists(md):
    old = open(md).read()
    if old.startswith("# "):
        head, _, rest = old.partition("\n\n")
        old = rest
header = "# Registry changes\n\nEvery sync that registered, de-registered or updated something. Newest first; full JSON per run in `changes/`.\n\n"
entries = (entry + old).split("\n## ")
keep = entries[0] + "".join("\n## " + e for e in entries[1:400])
open(md, "w").write(header + keep)
sys.exit(1)
