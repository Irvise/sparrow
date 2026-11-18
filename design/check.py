#!/usr/bin/env python3
"""Checks the Sparrow tree against design/rules.toml. Exit status 0 when every rule holds, 1 otherwise.

    python3 design/check.py            check, and list every violation
    python3 design/check.py --counts   print the unexplained UTF8_String conversions per file, for rules.toml

Needs Python 3.11 or later (tomllib). Reads files only.
"""
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = tomllib.loads((ROOT / "design" / "rules.toml").read_text())
failures: list[str] = []


def fail(where: str, message: str) -> None:
    failures.append(f"{where}: {message}")


def code_of(line: str) -> str:
    """The line without its comment and with string literals blanked, so neither is mistaken for code."""
    line = re.sub(r'"([^"]|"")*"', '""', line)
    return line.split("--", 1)[0]


def sources(crate: str, pattern: str = "*.ad[sb]") -> list[pathlib.Path]:
    return sorted((ROOT / crate / "src").rglob(pattern))


def relative(path: pathlib.Path) -> str:
    return str(path.relative_to(ROOT))


crates = sorted(p.name for p in ROOT.glob("sparrow_*") if (p / "alire.toml").is_file())

# --- the unit each crate owns ------------------------------------------------------------------------------
UNIT = re.compile(r"^\s*(?:private\s+)?(?:generic\s+)?(?:package|procedure|function)\s+(?!body\b)([A-Za-z0-9_.]+)",
                  re.IGNORECASE | re.MULTILINE)
owner: dict[str, str] = {}
spec_of: dict[str, pathlib.Path] = {}
body_of: dict[str, pathlib.Path] = {}
for crate in crates:
    for spec in sources(crate, "*.ads"):
        match = UNIT.search("\n".join(code_of(l) for l in spec.read_text(encoding="latin-1").splitlines()))
        if match:
            name = match.group(1).lower()
            owner.setdefault(name, crate)
            spec_of.setdefault(name, spec)
            body = spec.with_suffix(".adb")
            if body.is_file():
                body_of.setdefault(name, body)


def owner_of(unit: str) -> str | None:
    """The crate owning unit, or the nearest parent unit for a child declared elsewhere."""
    parts = unit.lower().split(".")
    while parts:
        if ".".join(parts) in owner:
            return owner[".".join(parts)]
        parts.pop()
    return None


# --- 0012: crate dependencies ------------------------------------------------------------------------------
allowed = {crate: set(deps) for crate, deps in RULES["crates"].items()}
for crate in crates:
    if crate not in allowed:
        fail(f"{crate}/alire.toml", "crate missing from design/rules.toml [crates]")
        continue
    manifest = tomllib.loads((ROOT / crate / "alire.toml").read_text())
    declared = {name for table in manifest.get("depends-on", []) for name in table if name.startswith("sparrow_")}
    if declared != allowed[crate]:
        fail(f"{crate}/alire.toml", f"depends on {sorted(declared)}, rules allow exactly {sorted(allowed[crate])}")
    project = (ROOT / crate / f"{crate}.gpr").read_text()
    withed = set(re.findall(r'^\s*with\s+"(sparrow_\w+)\.gpr"', project, re.MULTILINE))
    if withed != allowed[crate]:
        fail(f"{crate}/{crate}.gpr", f'withs {sorted(withed)}, rules allow exactly {sorted(allowed[crate])}')
    for source in sources(crate):
        text = "\n".join(code_of(l) for l in source.read_text(encoding="latin-1").splitlines())
        for clause in re.finditer(r"\bwith\s+([A-Za-z0-9_., \n]+?);", text):
            for unit in re.split(r"\s*,\s*", clause.group(1).strip()):
                if not unit.lower().startswith("sparrow."):
                    continue
                home = owner_of(unit)
                if home and home != crate and home not in allowed[crate]:
                    fail(relative(source), f"with {unit}: {home} is not a dependency of {crate}")
for crate in allowed:
    if crate not in crates:
        fail("design/rules.toml", f"[crates] names {crate}, which does not exist")

# --- 0001, 0002: C linkage ---------------------------------------------------------------------------------
BINDING = re.compile(r"Convention\s*=>\s*C\b|pragma\s+Import\b|\bInterfaces\.C\b|External_Name", re.IGNORECASE)
linkage = {crate: set(libs) for crate, libs in RULES["c_linkage"].items()}
forbidden = set(RULES["forbidden_libraries"]["names"])
excepted = {crate: set(libs) for crate, libs in RULES["forbidden_libraries"]["except"].items()}
for crate in crates:
    for source in sources(crate):
        for number, line in enumerate(source.read_text(encoding="latin-1").splitlines(), 1):
            if BINDING.search(code_of(line)) and crate not in linkage:
                fail(f"{relative(source)}:{number}", f"binds C, but {crate} is not in [c_linkage]")
                break
    project = (ROOT / crate / f"{crate}.gpr").read_text()
    for library in re.findall(r'"-l([A-Za-z0-9_]+)"', project):
        if library not in linkage.get(crate, set()):
            fail(f"{crate}/{crate}.gpr", f"links -l{library}, not allowed for {crate} by [c_linkage]")
        if library in forbidden and library not in excepted.get(crate, set()):
            fail(f"{crate}/{crate}.gpr", f"links -l{library}, a forbidden library")

# --- 0004: proved units ------------------------------------------------------------------------------------
def package_aspects(path: pathlib.Path, body: bool) -> str:
    """The text from a package's declaration to its 'is': where its SPARK_Mode is given."""
    text = "\n".join(code_of(l) for l in path.read_text(encoding="latin-1").splitlines())
    keyword = r"package\s+body" if body else r"package"
    match = re.search(rf"\b{keyword}\s+[A-Za-z0-9_.]+(.*?)\bis\b", text, re.IGNORECASE | re.DOTALL)
    return match.group(1) if match else ""


for unit in RULES["proved"]["units"]:
    key = unit.lower()
    if key not in spec_of:
        fail("design/rules.toml", f"[proved] names {unit}, which does not exist")
        continue
    for path, body in [(spec_of[key], False)] + ([(body_of[key], True)] if key in body_of else []):
        aspects = package_aspects(path, body)
        if not re.search(r"SPARK_Mode", aspects) or re.search(r"SPARK_Mode\s*=>\s*Off", aspects):
            fail(relative(path), f"{unit} must be SPARK (decision 0004), and its {'body' if body else 'spec'} is not")

script = (ROOT / RULES["proved"]["prove_script"]).read_text()
listed = set(re.findall(r"\bsparrow_\w+", script))
for crate in crates:
    has_spark = any(re.search(r"SPARK_Mode(?!\s*=>\s*Off)", code_of(line))
                    for source in sources(crate)
                    for line in source.read_text(encoding="latin-1").splitlines())
    if has_spark and crate not in listed:
        fail(RULES["proved"]["prove_script"], f"{crate} has SPARK code but is not proved")

# --- 0005: bytes and text ----------------------------------------------------------------------------------
CONVERSION = re.compile(r"(?<![:\w])\s*\bUTF8_String\s*\(")
DECLARATION = re.compile(r"(:\s*(aliased\s+)?(constant\s+)?|\bof\s+|\bnew\s+|\bsubtype\s+\w+\s+is\s+)UTF8_String\s*\(",
                         re.IGNORECASE)
marker = RULES["text_conversions"]["justification"]
known = RULES["text_conversions"]["known_unexplained"]
counts: dict[str, int] = {}
for crate in crates:
    for source in sources(crate):
        lines = source.read_text(encoding="latin-1").splitlines()
        for number, line in enumerate(lines, 1):
            code = code_of(line)
            found = len(re.findall(r"\bUTF8_String\s*\(", code)) - len(DECLARATION.findall(code))
            if found <= 0:
                continue
            explained = marker in line or (number > 1 and marker in lines[number - 2])
            if not explained:
                counts[relative(source)] = counts.get(relative(source), 0) + found
if "--counts" in sys.argv:
    for path, count in sorted(counts.items()):
        print(f'"{path}" = {count}')
    sys.exit(0)
for path in sorted(set(counts) | set(known)):
    now, before = counts.get(path, 0), known.get(path, 0)
    if now > before:
        fail(path, f"{now - before} UTF8_String (...) conversion(s) without a '{marker}' reason (decision 0005)")
    elif now < before:
        fail("design/rules.toml", f"{path} now has {now} unexplained conversions: lower its count from {before}")

# --- 0007: portable specs ----------------------------------------------------------------------------------
portable = RULES["portable_specs"]
for spec in sorted((ROOT / portable["directory"]).glob("*.ads")):
    for number, line in enumerate(spec.read_text(encoding="latin-1").splitlines(), 1):
        for word in portable["forbidden"]:
            if word.lower() in code_of(line).lower():
                fail(f"{relative(spec)}:{number}", f"'{word}' in a portable spec (decision 0007)")

# --- 0008: toolchain ---------------------------------------------------------------------------------------
toolchain = RULES["toolchain"]
for crate in crates:
    manifest = tomllib.loads((ROOT / crate / "alire.toml").read_text())
    gnat = [table["gnat"] for table in manifest.get("depends-on", []) if "gnat" in table]
    switches = manifest.get("build-switches", {}).get("*", {})
    if gnat != [toolchain["gnat"]]:
        fail(f"{crate}/alire.toml", f'gnat must be "{toolchain["gnat"]}", is {gnat}')
    if switches.get("ada_version") != toolchain["ada_version"]:
        fail(f"{crate}/alire.toml", f'ada_version must be "{toolchain["ada_version"]}"')
    if toolchain["line_length"] not in switches.get("style_checks", []):
        fail(f"{crate}/alire.toml", f'style_checks must include "{toolchain["line_length"]}"')

# -----------------------------------------------------------------------------------------------------------
for failure in failures:
    print(failure)
if failures:
    print(f"\n{len(failures)} design rule violation(s). See design/README.md.", file=sys.stderr)
    sys.exit(1)
print("design rules: all hold")
