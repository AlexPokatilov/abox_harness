#!/usr/bin/env bash
# lab7 — build both Kustomizations offline, with and without lab7/patches/,
# and show what the patches change. No cluster needed.
#
#   bash lab7/check-patches.sh            # diff of object lists
#   bash lab7/check-patches.sh render     # full patched YAML to stdout
#
# Builds from the local releases/ — valid as long as the checkout matches the
# pinned artifact tag (v0.11.33, see bootstrap/flux.tf).
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ks() {  # ks <name> <patches-file|""> > file
  printf 'apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: %s\n  namespace: flux-system\nspec:\n  interval: 2m\n  path: ./\n  prune: true\n  sourceRef:\n    kind: OCIRepository\n    name: releases\n' "$1"
  if [ -n "$2" ]; then printf '  patches:\n'; sed 's/^/    /' "$2"; fi
}

build() {  # build <name> <path> <ks-file>
  flux build kustomization "$1" --path "$2" --kustomization-file "$3" --dry-run
}

objects() {  # one "kind ns/name" per object
  awk '/^---/{if(k)print k" "ns"/"n; k=n=ns=""} /^kind:/{k=$2} /^  name:/{if(!n)n=$2} /^  namespace:/{if(!ns)ns=$2} END{if(k)print k" "ns"/"n}' | sort
}

for pair in "releases-crds:releases/crds:lab7/patches/crds.yaml" "releases:releases:lab7/patches/releases.yaml"; do
  IFS=: read -r name path patches <<<"$pair"
  ks "$name" ""         > "$tmp/$name.orig.yaml"
  ks "$name" "$patches" > "$tmp/$name.lab7.yaml"
  build "$name" "$path" "$tmp/$name.orig.yaml" > "$tmp/$name.orig.out"
  build "$name" "$path" "$tmp/$name.lab7.yaml" > "$tmp/$name.lab7.out"

  if [ "${1:-}" = render ]; then cat "$tmp/$name.lab7.out"; echo "---"; continue; fi

  echo "=== $name: $(objects < "$tmp/$name.orig.out" | wc -l) → $(objects < "$tmp/$name.lab7.out" | wc -l) objects ==="
  diff <(objects < "$tmp/$name.orig.out") <(objects < "$tmp/$name.lab7.out") | sed -n 's/^< /  - /p; s/^> /  + /p' || true
  # values patches show up as content changes, not as object changes
  diff -q "$tmp/$name.orig.out" "$tmp/$name.lab7.out" >/dev/null && echo "  (no content change)"
done

echo "=== guard: flux-system Namespace must survive ==="
objects < "$tmp/releases.lab7.out" | grep -qx "Namespace /flux-system" \
  && echo "  ✓ present" || { echo "  ✗ MISSING — a patch deletes flux-system"; exit 1; }
