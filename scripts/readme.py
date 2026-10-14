#!/usr/bin/env python3
"""Refresh the live numbers in README.md from dist/index.json."""
import json, sys, re
meta = json.load(open(sys.argv[1]))
readme = sys.argv[2]
text = open(readme).read()
block = (f"<!-- stats:start -->\n"
         f"| | |\n|---|---|\n"
         f"| Formulae registered | **{meta['formulae']:,}** |\n"
         f"| Casks registered | **{meta['casks']:,}** |\n"
         f"| Last sync | `{meta['synced_at']}` |\n"
         f"| Index size | {meta['files']['index.pour.gz']['size']/1e6:.1f} MB (gzip) |\n"
         f"| SHA-256 | `{meta['files']['index.pour.gz']['sha256'][:16]}…` |\n"
         f"<!-- stats:end -->")
new = re.sub(r"<!-- stats:start -->.*?<!-- stats:end -->", block, text, flags=re.S)
open(readme, "w").write(new)
