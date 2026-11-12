#!/usr/bin/env python3
"""Exports projects from a Margin archive as the demo a release ships with.

    scripts/export-demo.py <archive folder> <out folder> <project> [<project> ...]

Writes <out>/entries.json, <out>/summaries.json and <out>/images/, in the
shape DemoData.seed copies into a new user's archive: files in images/ keep
their plain names and the entries refer to them as "demo-<name>".

Also the parts that make the demo work without API keys: copied HTML sites
(<out>/sites/, for "Open in browser"), the cluster map's layout and group
names, and the read captures (embeddings), only for the exported projects.
"""
import json
import os
import shutil
import sys

source, out, projects = sys.argv[1], sys.argv[2], set(sys.argv[3:])
images = os.path.join(source, "images")

entries = json.load(open(os.path.join(source, "entries.json")))
kept = [e for e in entries if e.get("project") in projects]

shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "images"))


def bundle(name):
    """Copies one of the archive's files; returns how the entry names it now."""
    plain = name[len("demo-"):] if name.startswith("demo-") else name
    path = os.path.join(images, name)
    if not os.path.isfile(path):
        return name
    target = os.path.join(out, "images", plain)
    if not os.path.exists(target):
        shutil.copy2(path, target)
    return "demo-" + plain


def rewrite(value):
    """Every string that names a file in the archive points at the bundled copy."""
    if isinstance(value, str):
        return bundle(value) if os.path.isfile(os.path.join(images, value)) else value
    if isinstance(value, list):
        return [rewrite(v) for v in value]
    if isinstance(value, dict):
        return {k: rewrite(v) for k, v in value.items()}
    return value


kept = [rewrite(e) for e in kept]
json.dump(kept, open(os.path.join(out, "entries.json"), "w"), indent=1)

# Headlines and summaries, only those made entirely from the kept captures.
ids = {e["id"][:8].upper() for e in kept}
summaries_path = os.path.join(source, "summaries.json")
summaries = json.load(open(summaries_path)) if os.path.exists(summaries_path) else {}
summaries = {k: v for k, v in summaries.items() if v.get("sources") and all(s.upper() in ids for s in v["sources"])}
json.dump(summaries, open(os.path.join(out, "summaries.json"), "w"), indent=1)

# Copied HTML sites (Claude captures and iterations), at the same relative path.
sites = 0
for e in kept:
    folder = e.get("siteFolder")
    if not folder or not folder.startswith("sites/") or ".." in folder:
        continue
    src = os.path.join(source, folder)
    if os.path.isdir(src) and not os.path.exists(os.path.join(out, folder)):
        shutil.copytree(src, os.path.join(out, folder))
        sites += 1


def keep_json(name, keep):
    path = os.path.join(source, name)
    if not os.path.exists(path):
        return 0
    data = json.load(open(path))
    if not isinstance(data, dict):
        return 0
    data = {k: v for k, v in data.items() if keep(k)}
    json.dump(data, open(os.path.join(out, name), "w"), indent=1)
    return len(data)


full_ids = {e["id"] for e in kept}
maps = keep_json("map-arrangement.json", lambda k: k in projects)
keep_json("map-edits.json", lambda k: k in projects)
names = keep_json("pattern-names.json", lambda k: k.split("|", 1)[0] in projects)
keep_json("patterns.json", lambda k: k in projects)
read = keep_json("embeddings.json", lambda k: k in full_ids)

files = len(os.listdir(os.path.join(out, "images")))
counts = {p: sum(1 for e in kept if e.get("project") == p) for p in sorted(projects)}
print(f"Exported {counts}, {files} files, {len(summaries)} summaries, {sites} sites, "
      f"{maps} map layouts, {names} group names, {read} read captures to {out}")
