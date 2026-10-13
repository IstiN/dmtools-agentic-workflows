#!/usr/bin/env python3
"""Render the OLD inline body for an A/B scenario: snapshot -> manifest slice
-> the manifest's documented ${{ }} -> env rewrites. The output is what the
step executed on the pre-de-bloat workflow, adapted to run standalone exactly
like the extracted script does. Gate 4 re-proves: this output == the new
script's body, byte for byte."""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import stage2_manifest as M
import extract_stage2 as X


def render(script_name: str) -> str:
    e = next((x for x in M.MANIFEST if x["script"] == script_name), None) \
        or next(x for x in M.STAGE1 if x["script"] == script_name)
    snap = X.parse_steps(X.snapshot_workflow())
    lines = next(l for n, l, _ in snap[e["job"]] if n == e["step"])
    if e.get("slice"):
        lines, _, _ = X.slice_body(lines, e["slice"][0], e["slice"][1])
    body = X.dedent_n(lines, e.get("dedent", 8))
    if e.get("strip"):
        body = [ln for ln in body if ln not in e["strip"]]
    text = "\n".join(body) + "\n"
    return X.apply_rewrites(text, e.get("rewrites", []))


def script_body(script_name: str) -> str:
    p = X.ROOT / "scripts" / script_name
    text = p.read_text()
    # strip the 5-line provenance header (shebang + 4 comment lines)
    lines = text.split("\n")
    assert lines[0].startswith("#!"), p
    i = next(k for k in range(1, len(lines)) if not lines[k].startswith("#"))
    return "\n".join(lines[i:])


if __name__ == "__main__":
    mode, name = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else "-"
    if mode == "old":
        if out == "-":
            sys.stdout.write(render(name))
        else:
            pathlib.Path(out).write_text(render(name))
    elif mode == "check":
        old, new = render(name), script_body(name)
        if old != new:
            import difflib
            sys.stdout.writelines(difflib.unified_diff(
                old.splitlines(True), new.splitlines(True),
                "snapshot-body+rewrites", f"scripts/{name}", n=1))
            sys.exit(1)
    else:
        sys.exit(f"unknown mode {mode}")
