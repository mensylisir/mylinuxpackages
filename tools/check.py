#!/usr/bin/env python3
"""Pre-push sanity checks for mylinuxpackages recipes.

Runs entirely offline: syntax, recipe metadata, local source hashes and a
heuristic for "writes into a directory that the stage script never creates".
These are the failure modes that only surface minutes into a CI run, so they
belong here.
"""
from __future__ import annotations

import glob
import hashlib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


# --- 1. syntax ---------------------------------------------------------------
def check_syntax() -> None:
    scripts = ["build-package.sh"]
    scripts += sorted(glob.glob("lib/*.sh"))
    scripts += sorted(glob.glob("recipes/**/*.sh", recursive=True))
    for s in scripts:
        p = os.path.join(ROOT, s)
        if not os.path.exists(p):
            continue
        r = run(["bash", "-n", p])
        if r.returncode != 0:
            err(f"syntax: {s}: {r.stderr.strip()}")

    for s in sorted(glob.glob("lib/patch/*.cjs")) + sorted(glob.glob("recipes/**/*.cjs", recursive=True)):
        p = os.path.join(ROOT, s)
        if not os.path.exists(p):
            continue
        r = run(["node", "--check", p])
        if r.returncode != 0:
            err(f"node syntax: {s}: {r.stderr.strip().splitlines()[-1] if r.stderr else ''}")


# --- 2. recipe metadata ------------------------------------------------------
REQUIRED = ["APP_ID", "PKG_NAME", "VERSION", "DISPLAY_NAME", "STRING_NAME", "URL", "DESCRIPTION"]


def parse_conf(path: str) -> dict:
    """Minimal parser for the simple KEY="value" / ARRAY=(...) recipe format."""
    text = open(path, encoding="utf-8").read()
    values: dict[str, str] = {}
    for key in REQUIRED:
        m = re.search(rf'^{key}="([^"]*)"', text, re.M)
        if m:
            values[key] = m.group(1)
    return values


def array_items(text: str, name: str) -> list[str]:
    m = re.search(rf"^{name}=\((.*?)^\)", text, re.M | re.S)
    if not m:
        return []
    body = re.sub(r"#[^\n]*", "", m.group(1))
    return [x.strip().strip('"').strip("'") for x in body.splitlines() if x.strip().strip('"').strip("'")]


def check_recipes() -> None:
    for conf in sorted(glob.glob(os.path.join(ROOT, "recipes/*/recipe.conf"))):
        rid = os.path.basename(os.path.dirname(conf))
        text = open(conf, encoding="utf-8").read()
        values = parse_conf(conf)
        for key in REQUIRED:
            if not values.get(key):
                err(f"{rid}: missing {key}")
        ver = values.get("VERSION", "")
        if ver and not re.fullmatch(r"[0-9][A-Za-z0-9.+~:-]*", ver):
            err(f"{rid}: illegal deb version {ver!r} (allowed: alnum . + ~ : -)")
        if "-" in ver:
            err(f"{rid}: rpm Version may not contain '-' ({ver})")
        pkg = values.get("PKG_NAME", "")
        if pkg and not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", pkg):
            err(f"{rid}: illegal package name {pkg!r}")

        # Conflict/replacement declarations must be legal package names and
        # must never target this package itself.
        for arr in ("CONFLICTS_DEB", "REPLACES_DEB", "CONFLICTS_RPM", "OBSOLETES_RPM"):
            for item in array_items(text, arr):
                if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", item):
                    err(f"{rid}: illegal name in {arr}: {item!r}")
                if item == pkg:
                    err(f"{rid}: {arr} conflicts with its own package name {pkg}")

        # stage script must exist for STAGE_MODE=recipe
        mode = re.search(r'^STAGE_MODE="([^"]*)"', text, re.M)
        has_stage = os.path.exists(os.path.join(os.path.dirname(conf), "stage.sh"))
        if (mode and mode.group(1) == "recipe") and not has_stage:
            err(f"{rid}: STAGE_MODE=recipe but no stage.sh")
        if not mode and not has_stage:
            err(f"{rid}: neither STAGE_MODE nor stage.sh")

        # local sources must exist and match their recorded hash
        for item in array_items(text, "SOURCES"):
            parts = item.split("|")
            if len(parts) != 3:
                err(f"{rid}: malformed SOURCES entry {item!r}")
                continue
            filename, url, checksum = parts
            if not url.startswith("local:"):
                continue
            local = os.path.join(os.path.dirname(conf), url[len("local:"):])
            if not os.path.exists(local):
                err(f"{rid}: missing local source {url[len('local:'):]}")
                continue
            if re.fullmatch(r"[0-9a-f]{64}", checksum):
                h = hashlib.sha256(open(local, "rb").read()).hexdigest()
                if h != checksum:
                    err(f"{rid}: sha256 mismatch for {os.path.basename(local)}")


# --- 3. shell escaping in generated launchers --------------------------------
def check_stage_escapes() -> None:
    """`printf '...\\$VAR...'` / `echo '...\\$VAR...'` never expands.

    Single quotes keep the backslash, so the installed launcher contains a
    literal "\\$BASE/foo" and exec fails with "not found". This shipped once
    (mimo-desktop) — catch it before the build.
    """
    for stage in sorted(glob.glob(os.path.join(ROOT, "recipes/*/stage.sh"))):
        rid = os.path.basename(os.path.dirname(stage))
        for i, line in enumerate(open(stage, encoding="utf-8"), 1):
            if re.search(r"(?:printf|echo)\s+'[^']*\\\$[A-Za-z_{]", line):
                err(f"{rid}: stage.sh:{i}: \\$ inside single quotes never expands: {line.strip()[:90]}")


# --- 4. writes into directories nobody creates -------------------------------
WRITE_PATTERNS = [
    re.compile(r'(?:^|&&|\|\||;|\bthen\b)\s*install\s+-(?!D|d)[0-9a-zA-Z]*\s+.*?"(\$(?:\{ROOT\}|ROOT)[^"]*)"'),
    re.compile(r'cat\s*>\s*"(\$(?:\{ROOT\}|ROOT)[^"]*)"'),
    re.compile(r'ln\s+-s[a-z]*\s+.*?"(\$(?:\{ROOT\}|ROOT)[^"]*)"'),
    re.compile(r'(?:^|&&|\|\||;)\s*cp\s+.*?"(\$(?:\{ROOT\}|ROOT)[^"]*)"'),
]
MKDIR_PATTERNS = [
    re.compile(r"mkdir\s+-p\s+(.*)$"),
    re.compile(r"install\s+-d(?:m?[0-7]+)?\s+(.*)$"),
]


def dirs_created(lines: list[str]) -> set[str]:
    out: set[str] = set()
    for line in lines:
        for pat in MKDIR_PATTERNS:
            m = pat.search(line)
            if not m:
                continue
            for token in re.findall(r'"([^"]+)"', m.group(1)) + m.group(1).split():
                token = token.strip().strip('"')
                if token.startswith("$ROOT"):
                    out.add(token.replace("${ROOT}", "$ROOT"))
    return out


def check_stage_dirs() -> None:
    for stage in sorted(glob.glob(os.path.join(ROOT, "recipes/*/stage.sh"))):
        rid = os.path.basename(os.path.dirname(stage))
        raw = open(stage, encoding="utf-8").read()
        # join backslash continuations so multi-line mkdir/install -d is one line
        raw = re.sub(r"\\\n\s*", " ", raw)
        lines = raw.splitlines()
        created = dirs_created(lines)
        created_dirs = {c for c in created if not os.path.splitext(c)[1]}
        for line in lines:
            for pat in WRITE_PATTERNS:
                m = pat.search(line)
                if not m:
                    continue
                dest = m.group(1).replace("${ROOT}", "$ROOT")
                # "$ROOT" itself is the only variable in the prefix we expect.
                rest = dest[len("$ROOT"):]
                parts = rest.split("/")
                var_at = [i for i, seg in enumerate(parts) if "$" in seg]
                # A variable only in the final segment is still fine: the parent
                # directory is literal. A variable mid-path cannot be judged.
                if var_at:
                    # With a variable anywhere in the path, the literal prefix
                    # before the first variable is what must already exist.
                    parent = "$ROOT" + "/".join(parts[: var_at[0]])
                    if parent == "$ROOT":
                        continue
                else:
                    parent = "$ROOT" + os.path.dirname(rest)
                # A created child directory implies its parents exist.
                if not any(parent == d or parent.startswith(d + "/") or d.startswith(parent + "/")
                           for d in created_dirs):
                    err(f"{rid}: writes {dest} but never creates {parent}")


def main() -> int:
    check_syntax()
    check_recipes()
    check_stage_escapes()
    check_stage_dirs()

    for w in warnings:
        print(f"warn: {w}")
    for e in errors:
        print(f"ERROR: {e}")
    print(f"\n{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
