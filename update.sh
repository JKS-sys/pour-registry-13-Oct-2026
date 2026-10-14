#!/usr/bin/env bash
# pour-registry · update.sh — one script that does everything:
#   fetch Homebrew's formula and cask API → build the Pour index →
#   register new packages, de-register removed ones (diff) → publish
#   (GitHub Release "latest", Cloudflare R2, this repo's changes log + README).
#
# Runs every few hours in GitHub Actions and also by hand:
#   bash update.sh            full run
#   bash update.sh --no-publish   build and diff only
#
# Needs: curl, python3, a `pour` binary (POUR_BIN, ../pour/target/release/pour,
# or the newest GitHub release), and for publishing: gh (GH_TOKEN) and
# wrangler (CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID).
set -euo pipefail
cd "$(dirname "$0")"

API=https://formulae.brew.sh/api
BUCKET=${POUR_R2_BUCKET:-pour-registry-13-oct-2026}
PUBLISH=1
for a in "$@"; do case "$a" in --no-publish) PUBLISH=0;; esac; done
mkdir -p .cache dist changes

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# 1. A pour binary.
POUR=${POUR_BIN:-}
if [ -z "$POUR" ] && command -v pour >/dev/null 2>&1; then POUR=pour; fi
if [ -z "$POUR" ] && [ -x ../pour/target/release/pour ]; then POUR=../pour/target/release/pour; fi
if [ -z "$POUR" ]; then
  say "fetching the newest pour release"
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  case "$os" in darwin) os=macos;; esac
  case "$arch" in aarch64|arm64) arch=arm64;; x86_64|amd64) arch=x86_64;; esac
  curl -fsSL -o .cache/pour "https://ipconfig.co.network/pour/dl/pour-$os-$arch" || curl -fsSL -o .cache/pour "https://github.com/JKS-sys/pour-13-Oct-2026/releases/latest/download/pour-$os-$arch"
  chmod +x .cache/pour && POUR=.cache/pour
fi
say "using $POUR ($($POUR --version))"

# 2. Homebrew's API, cached with ETags so an unchanged run costs one request each.
fetch() { # fetch <name>
  local name=$1 etag_file=".cache/$1.etag" out=".cache/$1.json" code
  local hdr=()
  [ -f "$etag_file" ] && [ -f "$out" ] && hdr=(-H "If-None-Match: $(cat "$etag_file")")
  code=$(curl -sS --compressed -o ".cache/$name.json.new" -D ".cache/$name.headers" -w '%{http_code}' "${hdr[@]}" "$API/$name.json" || echo 000)
  case "$code" in
    200) mv ".cache/$name.json.new" "$out"; grep -i '^etag:' ".cache/$name.headers" | sed 's/^[Ee][Tt][Aa][Gg]: *//' | tr -d '\r' > "$etag_file"; echo changed;;
    304) rm -f ".cache/$name.json.new"; echo same;;
    *) rm -f ".cache/$name.json.new"; echo "formulae.brew.sh answered $code for $name" >&2; [ -f "$out" ] || exit 1; echo same;;
  esac
}
say "fetching formula.json and cask.json"
F=$(fetch formula); C=$(fetch cask)
say "formulae: $F · casks: $C"

# 3. Previous index, for the diff (from the last release, else from dist/).
PREV=""
if [ -f dist/index.pour.gz ]; then cp dist/index.pour.gz .cache/previous.pour.gz; PREV=.cache/previous.pour.gz
elif curl -fsSL -o .cache/previous.pour.gz https://github.com/JKS-sys/pour-registry-13-Oct-2026/releases/latest/download/index.pour.gz 2>/dev/null; then PREV=.cache/previous.pour.gz; fi

# 4. Build.
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
say "building the index"
ARGS=(registry build --formulae .cache/formula.json --casks .cache/cask.json --out dist/index.pour.gz --search-out dist/search.json --meta "source=$API" --meta "synced_at=$STAMP" --meta "registry=https://github.com/JKS-sys/pour-registry-13-Oct-2026" --meta "owner=Jagadeesh Kumar S")
[ -n "$PREV" ] && ARGS+=(--diff "$PREV" --diff-out dist/changes.json)
"$POUR" "${ARGS[@]}"
STATS=$("$POUR" registry stats dist/index.pour.gz)
NF=$(printf '%s' "$STATS" | python3 -c 'import sys,json; print(json.load(sys.stdin)["formulae"])')
NC=$(printf '%s' "$STATS" | python3 -c 'import sys,json; print(json.load(sys.stdin)["casks"])')
SHA=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' dist/index.pour.gz)
SIZE=$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' dist/index.pour.gz)

# 5. Register / de-register log.
CHANGED=0
if [ -f dist/changes.json ]; then
  python3 scripts/changes.py dist/changes.json "$STAMP" changes CHANGES.md && CHANGED=$? || CHANGED=$?
fi
python3 - "$STAMP" "$NF" "$NC" "$SHA" "$SIZE" > dist/index.json <<'PY'
import json,sys
stamp,nf,nc,sha,size=sys.argv[1:6]
ch={}
try: ch=json.load(open("dist/changes.json"))
except Exception: pass
summary={k:{kk:len(v) for kk,v in ch.get(k,{}).items()} for k in ("formulae","casks")} if ch else {}
json.dump({"name":"pour-registry","synced_at":stamp,"formulae":int(nf),"casks":int(nc),
 "files":{"index.pour.gz":{"sha256":sha,"size":int(size),"url":"https://ipconfig.co.network/pour/registry/index.pour.gz",
 "mirror":"https://github.com/JKS-sys/pour-registry-13-Oct-2026/releases/latest/download/index.pour.gz"}},
 "changes":summary,"owner":"Jagadeesh Kumar S","source":"https://formulae.brew.sh/api"},sys.stdout,indent=1)
PY
python3 scripts/readme.py dist/index.json README.md
say "index: $NF formulae, $NC casks, $SIZE bytes, sha256 $SHA"

[ "$PUBLISH" = 1 ] || { say "built dist/ (not publishing)"; exit 0; }

# 6. Publish.
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  say "GitHub release 'latest'"
  REPO=${GITHUB_REPOSITORY:-JKS-sys/pour-registry-13-Oct-2026}
  if ! gh release view latest -R "$REPO" >/dev/null 2>&1; then
    gh release create latest -R "$REPO" --title "Pour registry — rolling" --notes "Rebuilt every few hours from Homebrew's API. Always the newest index." --latest
  fi
  gh release upload latest dist/index.pour.gz dist/index.json dist/search.json dist/changes.json -R "$REPO" --clobber 2>/dev/null || gh release upload latest dist/index.pour.gz dist/index.json dist/search.json -R "$REPO" --clobber
  gh release edit latest -R "$REPO" --notes "Synced $STAMP · $NF formulae · $NC casks · sha256 $SHA" >/dev/null || true
fi
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
  say "Cloudflare R2 ($BUCKET)"
  for f in index.pour.gz index.json search.json changes.json; do
    [ -f "dist/$f" ] || continue
    ct=application/json; [ "$f" = index.pour.gz ] && ct=application/gzip
    for try in 1 2 3; do
      if npx --yes wrangler@4 r2 object put "$BUCKET/$f" --file "dist/$f" --content-type "$ct" --remote >/dev/null 2>&1; then break; fi
      sleep $((try * 5))
    done
  done
fi
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  git config user.name "pour-registry bot"; git config user.email "JKS.sys@icloud.com"
  git add README.md CHANGES.md changes/ >/dev/null 2>&1 || true
  if ! git diff --cached --quiet; then
    git commit -qm "sync $STAMP: $NF formulae, $NC casks" && git push -q
  fi
fi
say "done"
