#!/usr/bin/env python3
"""Stage-2 de-bloat: byte-extract factory-teammate.yml domain run: bodies -> scripts/.

Reads the ORIGINAL bodies from the pre-de-bloat snapshot (a4cd62f = commit
before stage-1 0c3d268; its factory-teammate.yml carries every original
inline body), writes scripts/<name>.sh (shebang + provenance header + body
dedented by the 8-column block-scalar indent; the only content changes are
the manifest's documented ${{ }} -> env rewrites), then rewrites the
workflow in place: each body becomes the stage-1 delivery invocation
`run: bash -e "${RUNNER_TEMP}/factory-kit/scripts/<name>.sh"` plus a pointer
comment; manifest step_env entries are appended to the step's env: mapping;
the guard job gains the strict scripts/ fetch step.

One-shot migration tool (git is the undo). Every claim it makes about the
result is re-proven forever by scripts/ab_test/run_gates.sh gate 4 and the
A/B harness.
"""
import pathlib
import re
import subprocess
import sys

import stage2_manifest as M

ROOT = pathlib.Path(__file__).resolve().parents[2]
WF = ROOT / ".github/workflows/factory-teammate.yml"
OLD_SNAPSHOT = "a4cd62f"

GUARD_FETCH_STEP = """      - name: Fetch factory scripts (this repo @ invocation ref)
        # Stage-2 de-bloat delivery: the guard's domain step (scripts/
        # teammate-dispatch-gate.sh) rides the same immutable factory-kit
        # fetch as the teammate job — scripts/ is checked out at EXACTLY the
        # ref the caller invoked (github.workflow_ref), so the gate logic can
        # never skew from the workflow version that calls it. Strict, unlike
        # the teammate fetch: the guard has no FACTORY_ROOT fallback, so a
        # failed delivery must red the run, not silently skip the gate.
        env:
          AWF_REF: ${{ github.workflow_ref }}
        run: |
          ref="${AWF_REF##*@}"
          dir="${RUNNER_TEMP}/factory-kit"
          git init -q "$dir"
          git -C "$dir" remote add origin https://github.com/IstiN/dmtools-agentic-workflows.git
          git -C "$dir" fetch -q --depth 1 origin "$ref" \\
            || { echo "::error::factory scripts fetch failed at $ref — the dispatch gate cannot run"; exit 1; }
          git -C "$dir" checkout -q FETCH_HEAD -- scripts/
          [ -f "$dir/scripts/teammate-dispatch-gate.sh" ] \\
            || { echo "::error::scripts/teammate-dispatch-gate.sh missing at $ref"; exit 1; }
"""


def snapshot_workflow() -> str:
    return subprocess.run(
        ["git", "show", f"{OLD_SNAPSHOT}:.github/workflows/factory-teammate.yml"],
        check=True, capture_output=True, text=True, cwd=ROOT).stdout


def _get(node, key):
    for k, v in node.value:
        if k.value == key:
            return v
    return None


def parse_steps(text: str):
    """job -> ordered [(step_name, run_scalar_lines, scalar_start0)] via yaml marks."""
    import yaml
    out = {}
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    for jkey, jnode in _get(root, "jobs").value:
        steps = []
        snode = _get(jnode, "steps")
        if snode is None:
            continue
        for sval in snode.value:
            name, run = None, None
            for k, v in sval.value:
                if k.value == "name":
                    name = v.value
                elif k.value == "run":
                    run = v

            if run is not None:
                lines = text.splitlines()[run.start_mark.line:run.end_mark.line + 1]
                h = next((i for i, ln in enumerate(lines) if ln.strip() == "run: |"), None)
                if h is not None:
                    lines = lines[h + 1:]
                    start0 = run.start_mark.line + h + 1
                else:  # plain one-liner `run: cmd` (not part of the stage-2 manifest)
                    start0 = run.start_mark.line
                # end_mark can overshoot into the following token — the body is
                # the leading run of blank-or-10+-indent lines.
                while lines and (lines[-1].strip() == "" or not lines[-1].startswith(" " * 10)):
                    lines = lines[:-1]
                steps.append((name, lines, start0))
        out[jkey.value] = steps
    return out


def dedent_n(lines, n):
    out = []
    for ln in lines:
        if ln.strip() == "":
            out.append("")
            continue
        assert ln.startswith(" " * n), f"body line not {n}-indent: {ln!r}"
        out.append(ln[n:])
    while out and out[-1] == "":
        out.pop()
    return out


def dedent8(lines):
    return dedent_n(lines, 8)


def slice_body(lines, start_anchor, end_anchor):
    idx = [i for i, ln in enumerate(lines) if ln.strip() == start_anchor.strip()]
    assert len(idx) == 1, f"start anchor not unique: {start_anchor!r} -> {idx}"
    s = idx[0]
    j = next(i for i in range(s, len(lines)) if lines[i].strip() == end_anchor.strip())
    return lines[s:j + 1], s, j


def apply_rewrites(text, rewrites):
    for expr, repl in rewrites:
        text = re.sub(r"\$\{\{\s*" + re.escape(expr) + r"\s*\}\}", repl, text)
    assert "${{" not in text, f"unrewritten expression left: {text!r}"
    return text


def header(e):
    mode_note = {
        "exec": "Invoke with `bash -e` (the GH runner default\n"
                "# shell for inline `run:`); env block stays on the workflow step.",
        "source": "Invoke SOURCED (`. script`) from the run step: the dmtools\n"
                  "# self-heal must export the repaired PATH back into the step shell.",
        "bg": "Runs BACKGROUND (`... &`) from the run step, like the inline\n"
              "# `( ... ) &` subshell it replaces; env block stays on the workflow step.",
    }[e["mode"]]
    sliced = ", body slice" if e.get("slice") else ""
    return ("#!/usr/bin/env bash\n"
            f"# Extracted byte-for-byte from .github/workflows/factory-teammate.yml\n"
            f"# @ {OLD_SNAPSHOT} (step: {e['step']}{sliced}) — stage-2 de-bloat.\n"
            f"# Behavior contract: identical. {mode_note}\n")


def replacement_for(e, cur_lines, cur_run_lines, scalar_start):
    """Workflow surgery edit for manifest entry e: (start0, end0, repl_lines)."""
    name = e["script"]
    kit = '"${RUNNER_TEMP}/factory-kit/scripts/%s"' % name
    if e.get("slice"):
        s, j = slice_body(cur_run_lines, e["slice"][0], e["slice"][1])[1:]
    else:
        s, j = 0, len(cur_run_lines) - 1
    if e["mode"] == "exec":
        ptr = [f"        # Body: scripts/{name} (stage-2 de-bloat — byte-extracted, behavior-identical;",
               "        # delivered via the factory-kit fetch at the invocation ref).",
               f"        run: bash -e {kit}"]
        return (scalar_start - 1, scalar_start + j, ptr)
    inv = f'{e["invocation"]} ' if e.get("invocation") else ""
    if e["mode"] == "source":
        tagline = "          # SOURCED so the healed PATH propagates to the rest of the step)."
    else:
        tagline = "          # backgrounded like the inline `( ... ) &` subshell it replaces)."
    repl = [f"          # Body: scripts/{name} (stage-2 de-bloat — byte-extracted, behavior-identical;",
            tagline]
    if e["mode"] == "source":
        repl.append(f"          . {kit}")
    else:
        repl.append(f"          {inv}bash -e {kit} &")
    return (scalar_start + s, scalar_start + j, repl)


def main():
    snap = parse_steps(snapshot_workflow())
    cur_text = WF.read_text()
    cur = parse_steps(cur_text)
    cur_lines = cur_text.splitlines()

    edits = []  # (start0, end0_inclusive, replacement_lines)

    for e in M.MANIFEST:
        job, step, name = e["job"], e["step"], e["script"]
        orig_lines = next(l for n, l, _ in snap[job] if n == step)
        if e.get("slice"):
            body, s, j = slice_body(orig_lines, e["slice"][0], e["slice"][1])
        else:
            body, s, j = orig_lines, 0, len(orig_lines) - 1
        body_lines = dedent8(body)
        if e.get("strip"):
            body_lines = [ln for ln in body_lines if ln not in e["strip"]]
        text = "\n".join(body_lines) + "\n"
        text = apply_rewrites(text, e.get("rewrites", []))
        (ROOT / "scripts" / name).write_text(header(e) + text)

        # ── workflow surgery ──
        cur_run_lines = next(l for n, l, _ in cur[job] if n == step)
        assert "\n".join(cur_run_lines) == "\n".join(orig_lines), \
            f"snapshot drift on step: {step}"
        scalar_start = next(st for n, l, st in cur[job] if n == step)
        header_line = scalar_start - 1  # the `        run: |` line
        assert cur_lines[header_line].strip() == "run: |", cur_lines[header_line]
        edits.append(replacement_for(e, cur_lines, cur_run_lines, scalar_start))

    # step_env additions (create the env: block when the step has none)
    for e in M.MANIFEST:
        if not e.get("step_env"):
            continue
        name_idx = next(i for i, ln in enumerate(cur_lines)
                        if ln == f"      - name: {e['step']}")
        entries = [f"          {k}: {v}" for k, v in e["step_env"]]
        nxt = next((i for i in range(name_idx + 1, len(cur_lines))
                    if cur_lines[i].startswith("      - name:")), len(cur_lines))
        env_idx = next((i for i in range(name_idx + 1, nxt)
                        if cur_lines[i] == "        env:"), None)
        if env_idx is not None:
            j = env_idx + 1
            while j < len(cur_lines) and cur_lines[j].startswith("          "):
                j += 1
            edits.append((j, j - 1, entries))
        else:
            run_idx = next(i for i in range(name_idx + 1, nxt)
                           if cur_lines[i].startswith("        run:"))
            edits.append((run_idx, run_idx - 1, ["        env:"] + entries))

    # guard fetch step insertion (before the decide step)
    guard_idx = next(i for i, ln in enumerate(cur_lines)
                     if ln == "      - name: Decide whether this event is for the agent")
    edits.append((guard_idx, guard_idx - 1, GUARD_FETCH_STEP.rstrip("\n").splitlines()))

    for s, e0, repl in sorted(edits, key=lambda t: t[0], reverse=True):
        assert s <= e0 + 1 or repl, (s, e0)
        cur_lines[s:e0 + 1] = repl

    WF.write_text("\n".join(cur_lines) + "\n")
    print(f"extracted {len(M.MANIFEST)} scripts; workflow now {len(cur_lines)} lines")


if __name__ == "__main__":
    sys.exit(main())
