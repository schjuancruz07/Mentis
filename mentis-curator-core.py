#!/usr/bin/env python3
"""mentis-curator-core — auditoria deterministica de la memoria de Mentis (memoria/*.md).

Calco del curator de Claude Code (~/.claude/tools/curator/curator-core.py), adaptado a la
memoria de Mentis: un solo directorio memoria/ (no multi-proyecto), indice.md en vez de
MEMORY.md, frontmatter name/description/type (sin bloque metadata anidado).

Reporta:
  1. Entradas de indice.md que apuntan a archivos inexistentes (indice huerfano).
  2. Archivos de memoria no listados en indice.md (sin indexar).
  3. Links [[nombre]] que no matchean el slug `name:` de ninguna memoria (pendientes, no error).
  4. Duplicados lexicos (Jaccard sobre name+description+titulo) entre memorias.
  5. Referencias a rutas C:/Users/<usuario>\\Mentis\\... o ~/.claude/... que ya no existen en disco.

Invariante: NUNCA borra -- `archive` mueve a memoria/.archive/ y comenta la linea del indice.
Solo stdlib.

Subcomandos:
  report                    -> auditoria (default)
  archive <archivo.md>      -> archiva una memoria (recuperable)
"""
import sys, os, re, glob

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
MEMDIR = os.environ.get("MENTIS_MEMDIR") or os.path.join(HERE, "memoria")
INDEX = os.path.join(MEMDIR, "indice.md")
DUP_THRESHOLD = 0.5


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""


def _frontmatter_field(text, field):
    m = re.search(r"^---\s*\n(.*?)\n---", text, re.S)
    if not m:
        return ""
    fm = m.group(1)
    f = re.search(r"^%s:\s*(.+)$" % field, fm, re.M)
    return f.group(1).strip() if f else ""


def _load_memories():
    out = []
    for p in sorted(glob.glob(os.path.join(MEMDIR, "*.md"))):
        base = os.path.basename(p)
        if base == "indice.md":
            continue
        text = _read(p)
        out.append({
            "file": base,
            "path": p,
            "name": _frontmatter_field(text, "name") or os.path.splitext(base)[0],
            "description": _frontmatter_field(text, "description"),
            "type": _frontmatter_field(text, "type"),
            "body": text,
        })
    return out


def check_index(memories):
    """(huerfanas_en_indice, sin_indexar)."""
    idx = _read(INDEX)
    linked = set(re.findall(r"^-\s*\[([a-z0-9-]+)\]", idx, re.M))
    existing_slugs = {os.path.splitext(m["file"])[0] for m in memories}
    orphan_entries = sorted(s for s in linked if s not in existing_slugs)
    unindexed = sorted(s for s in existing_slugs if s not in linked)
    return orphan_entries, unindexed


def check_wikilinks(memories):
    names = {m["name"] for m in memories}
    pend = []
    for m in memories:
        for link in set(re.findall(r"\[\[([^\]]+)\]\]", m["body"])):
            if link not in names:
                pend.append((m["file"], link))
    return sorted(pend)


def _tokens(s):
    return {t for t in re.split(r"[^a-záéíóúñü0-9]+", s.lower()) if len(t) >= 4}


def check_duplicates(memories):
    sigs = []
    for m in memories:
        title = ""
        for line in m["body"].splitlines():
            if line.startswith("#"):
                title = line
                break
        sigs.append((m["file"], _tokens(f"{m['name']} {m['description']} {title}")))
    dups = []
    for i in range(len(sigs)):
        for j in range(i + 1, len(sigs)):
            a, b = sigs[i][1], sigs[j][1]
            if not a or not b:
                continue
            jac = len(a & b) / len(a | b)
            if jac >= DUP_THRESHOLD:
                dups.append((sigs[i][0], sigs[j][0], round(jac, 2)))
    return sorted(dups, key=lambda x: -x[2])


def check_stale_paths(memories):
    """Rutas C:/Users/<usuario>\\Mentis\\... o ~/.claude/... citadas que ya no existen en disco."""
    stale = []
    pat = re.compile(r"C:/Users/<usuario>\\[\w.\\-]+|~/\.claude/[\w./\-]+")
    for m in memories:
        for raw in set(pat.findall(m["body"])):
            cand = raw.rstrip(".,;:)")
            if cand.startswith("~/"):
                full = os.path.join(os.path.expanduser("~"), cand[2:])
            else:
                full = cand
            if not os.path.exists(full):
                stale.append((m["file"], cand))
    return sorted(stale)


def cmd_report():
    if not os.path.isdir(MEMDIR):
        print(f"[mentis-curator] no existe {MEMDIR}")
        return 0
    memories = _load_memories()
    orphans, unindexed = check_index(memories)
    pend_links = check_wikilinks(memories)
    dups = check_duplicates(memories)
    stale = check_stale_paths(memories)

    n_issues = len(orphans) + len(unindexed) + len(dups) + len(stale)
    print(f"\n=== memoria de Mentis · {len(memories)} memorias ===")
    if not memories and not orphans:
        print("    (vacio)")
        return 0
    if orphans:
        print("  [!] indice huerfano (indice.md apunta a slugs que no existen):")
        for s in orphans:
            print(f"      - {s}")
    if unindexed:
        print("  [!] sin indexar (existen pero no estan en indice.md):")
        for s in unindexed:
            print(f"      - {s}")
    if dups:
        print(f"  [!] posibles duplicados (Jaccard >= {DUP_THRESHOLD}):")
        for a, b, s in dups:
            print(f"      - {a} <-> {b} ({s})")
    if stale:
        print("  [!] referencias a rutas que ya no existen:")
        for f, p in stale:
            print(f"      - {f}: {p}")
    if pend_links:
        print("  [i] wikilinks pendientes (marcadores, no error):")
        for f, l in pend_links:
            print(f"      - {f}: [[{l}]]")
    if n_issues == 0:
        print("    OK -- sin problemas accionables")
    print(f"\n[mentis-curator] total problemas accionables: {n_issues}")
    print("[mentis-curator] nada se modifico. Para archivar: mentis-curator.sh archive <archivo.md>")
    return 0


def cmd_archive(fname):
    src = os.path.join(MEMDIR, fname)
    if not os.path.isfile(src):
        print(f"[mentis-curator] no existe: {src}")
        return 1
    adir = os.path.join(MEMDIR, ".archive")
    os.makedirs(adir, exist_ok=True)
    dst = os.path.join(adir, fname)
    if os.path.exists(dst):
        print(f"[mentis-curator] ya hay un archivado con ese nombre: {dst} -- no piso nada")
        return 1
    os.rename(src, dst)
    idx = _read(INDEX)
    slug = os.path.splitext(fname)[0]
    new_lines = []
    for line in idx.splitlines():
        if line.strip().startswith(f"- [{slug}]") and not line.lstrip().startswith("<!--"):
            new_lines.append(f"<!-- archivada {fname}: {line.strip()} -->")
        else:
            new_lines.append(line)
    if idx:
        with open(INDEX, "w", encoding="utf-8") as f:
            f.write("\n".join(new_lines) + "\n")
    print(f"[mentis-curator] archivada: {fname} -> {dst}")
    print(f"[mentis-curator] restaurar: mover el archivo de vuelta y des-comentar la linea en indice.md")
    return 0


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "report"
    if cmd == "report":
        return cmd_report()
    if cmd == "archive":
        if len(args) < 2:
            print("Uso: mentis-curator-core.py archive <archivo.md>")
            return 2
        return cmd_archive(args[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as ex:
        print(f"[mentis-curator] error: {ex}", file=sys.stderr)
        sys.exit(1)
