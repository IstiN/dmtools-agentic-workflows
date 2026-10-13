#!/usr/bin/env bash
# Static gates for the factory-teammate de-bloat (stages 1+2). Exit non-zero
# on the first red gate; prints PASS lines as it goes.
set -u
AB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${AB_ROOT}/../.." && pwd)"
OLD_SNAPSHOT="a4cd62f"
WF=".github/workflows/factory-teammate.yml"
rc=0

say()  { printf '%s\n' "$*"; }
fail() { printf 'GATE FAIL: %s\n' "$*" >&2; rc=1; }

# ── gate 1: strict duplicate-key YAML load, every workflow file ──
if python3 - "$REPO_ROOT" <<'PY'
import sys, pathlib, yaml
class L(yaml.SafeLoader): pass
def multi(loader, node, deep=False):
    seen=set(); res={}
    for k_node,v_node in node.value:
        k=loader.construct_object(k_node, deep=deep)
        if k in seen: raise yaml.constructor.ConstructorError(None,None,f"duplicate key {k!r}",node.start_mark)
        seen.add(k); res[k]=loader.construct_object(v_node, deep=deep)
    return res
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, multi)
root=pathlib.Path(sys.argv[1])
n=0
for p in sorted((root/'.github/workflows').glob('*.y*ml')):
    yaml.load(p.read_text(), Loader=L); n+=1
print(f"strict dup-key YAML load: {n} workflow files")
PY
then say "gate1 PASS: strict duplicate-key YAML load"; else fail "gate1"; fi

# ── gate 2: every workflow_call input has type: ──
if python3 - "$REPO_ROOT" <<'PY'
import sys, pathlib, yaml
class L(yaml.SafeLoader): pass
def multi(loader, node, deep=False):
    seen=set(); res={}
    for k_node,v_node in node.value:
        k=loader.construct_object(k_node, deep=deep)
        if k in seen: raise yaml.constructor.ConstructorError(None,None,f"duplicate key {k!r}",node.start_mark)
        seen.add(k); res[k]=loader.construct_object(v_node, deep=deep)
    return res
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, multi)
root=pathlib.Path(sys.argv[1]); bad=[]; total=0
for p in sorted((root/'.github/workflows').glob('*.y*ml')):
    d=yaml.load(p.read_text(), Loader=L) or {}
    on=d.get('on') or d.get(True) or {}
    wc=on.get('workflow_call')
    if not wc: continue
    for name,spec in (wc.get('inputs') or {}).items():
        total+=1
        if not isinstance(spec,dict) or 'type' not in spec:
            bad.append(f"{p.name}:{name}")
if bad:
    print("inputs missing type:", ", ".join(bad)); sys.exit(1)
print(f"workflow_call inputs typed: {total} across all workflows")
PY
then say "gate2 PASS: every workflow_call input has type:"; else fail "gate2"; fi

# ── gate 3: bash -n on every script ──
b3=0
for s in "$REPO_ROOT"/scripts/*.sh "$AB_ROOT"/*.sh "$AB_ROOT"/stubs/*; do
  [ -f "$s" ] || continue
  if ! bash -n "$s" 2>/tmp/ab_bashn_err; then
    fail "bash -n $s: $(cat /tmp/ab_bashn_err)"; b3=1
  fi
done
[ "$b3" -eq 0 ] && say "gate3 PASS: bash -n clean on all scripts"

# ── gate 4: byte-extraction proof + untouched-steps coverage ──
if python3 - "$REPO_ROOT" "$OLD_SNAPSHOT" <<'PY'
import sys, pathlib, subprocess
sys.path.insert(0, str(pathlib.Path(sys.argv[1], 'scripts/ab_test')))
import stage2_manifest as M
import render_old_body as R
import extract_stage2 as X
import yaml

repo=pathlib.Path(sys.argv[1]); snap_ref=sys.argv[2]
base_ref="0c3d268"  # stage-1 head = the state stage 2 started from
snap_text=subprocess.run(["git", "-C", str(repo), "show", f"{snap_ref}:.github/workflows/factory-teammate.yml"],
                         check=True, capture_output=True, text=True).stdout
base_text=subprocess.run(["git", "-C", str(repo), "show", f"{base_ref}:.github/workflows/factory-teammate.yml"],
                         check=True, capture_output=True, text=True).stdout
cur_text=(repo/'.github/workflows/factory-teammate.yml').read_text()

# 4a: every extracted script == snapshot body + manifest rewrites, byte for byte
# (stage-2 blocks + the two stage-1 blocks served by the A/B harness)
for e in list(M.MANIFEST) + list(M.STAGE1):
    old=R.render(e['script']); new=R.script_body(e['script'])
    if old!=new:
        raise SystemExit(f"byte-drift: scripts/{e['script']} != snapshot body (+rewrites)")
print(f"byte-extraction: {len(M.MANIFEST) + len(M.STAGE1)} scripts == snapshot bodies (+documented rewrites)")

# 4b: line coverage — every snapshot body line of each manifest entry exists in the script
for e in M.MANIFEST:
    old=R.render(e['script']).splitlines()
    new=R.script_body(e['script']).splitlines()
    missing=[ln for ln in old if ln not in new]
    if missing:
        raise SystemExit(f"coverage hole in scripts/{e['script']}: {missing[:3]}")
print("line coverage: every snapshot body line present in its script")

# 4c: everything NOT extracted is byte-identical to the stage-1 base (0c3d268),
#     parsed step-by-step; extracted steps may only swap run: for the invocation
#     (or the documented in-body slice replacement) and may only GROW env.
class L(yaml.SafeLoader): pass
def multi(loader, node, deep=False):
    seen=set(); res={}
    for k_node,v_node in node.value:
        k=loader.construct_object(k_node, deep=deep)
        if k in seen: raise yaml.constructor.ConstructorError(None,None,f"duplicate key {k!r}",node.start_mark)
        seen.add(k); res[k]=loader.construct_object(v_node, deep=deep)
    return res
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, multi)
base=yaml.load(base_text, Loader=L); cur=yaml.load(cur_text, Loader=L)
KEYS=('name','if','env','uses','with','run','id','timeout-minutes','continue-on-error')
slice_by_step={}
for e in M.MANIFEST:
    if e.get('slice'):
        slice_by_step.setdefault((e['job'],e['step']),[]).append(e)

def step_by_name(steps, name):
    return next(x for x in steps if x.get('name')==name)

def de10(t):
    return "\n".join(ln[10:] if ln.startswith(" " * 10) else ln for ln in t.split("\n"))

diffs=[]
for job in set(base['jobs']) | set(cur['jobs']):
    bs=base['jobs'].get(job,{}).get('steps') or []
    cs=cur['jobs'].get(job,{}).get('steps') or []
    if job=='guard' and len(cs)==len(bs)+1:
        # documented addition: the guard's strict scripts/ fetch step
        added=[s for s in cs if s.get('name') not in {x.get('name') for x in bs}]
        if [s.get('name') for s in added]!=['Fetch factory scripts (this repo @ invocation ref)'] or len(added)!=1:
            diffs.append("guard: unexpected step addition")
        cs=[s for s in cs if s.get('name')!='Fetch factory scripts (this repo @ invocation ref)']
    if len(bs)!=len(cs):
        diffs.append(f"{job}: step count {len(bs)} -> {len(cs)}"); continue
    for i,(s,c) in enumerate(zip(bs,cs)):
        tag=f"{job}/#{i} {s.get('name')}"
        for k in KEYS:
            if k=='env':
                se=s.get('env') or {}; ce=c.get('env') or {}
                for k2,v in se.items():
                    if ce.get(k2)!=v: diffs.append(f"{tag}: env {k2} changed/lost")
                for k2 in ce:
                    if k2 not in se: print(f"  note: {tag}: env +{k2} (rewrite carrier)")
                continue
            if k=='run':
                srun=(s.get('run') or ''); crun=(c.get('run') or '')
                if srun==crun: continue
                entries=slice_by_step.get((job,s.get('name')), [])
                whole=next((e for e in M.MANIFEST if (e['job'],e['step'])==(job,s.get('name')) and not e.get('slice')), None)
                if whole and crun==f'bash -e "${{RUNNER_TEMP}}/factory-kit/scripts/{whole["script"]}"':
                    continue
                if entries:
                    slines=srun.split('\n')
                    expected=list(slines)
                    for e2 in entries:
                        repl=X.replacement_for(e2, None, slines, 0)[2]
                        _,a,b=X.slice_body(expected, e2['slice'][0], e2['slice'][1])
                        expected[a:b+1]=repl
                    if de10('\n'.join(expected))!=de10(crun):
                        diffs.append(f"{tag}: run != documented slice replacement")
                    continue
                diffs.append(f"{tag}: run changed without manifest entry")
                continue
            if s.get(k)!=c.get(k):
                diffs.append(f"{tag}: {k} changed")
# guard job gained exactly the one documented delivery step
gk=[s.get('name') for s in cur['jobs']['guard']['steps']]
gb=[s.get('name') for s in base['jobs']['guard']['steps']]
new_steps=[n for n in gk if n not in gb]
if new_steps!=['Fetch factory scripts (this repo @ invocation ref)']:
    diffs.append(f"guard job unexpected new steps: {new_steps}")
if diffs:
    raise SystemExit("untouched-step drift:\n  " + "\n  ".join(diffs))
n_steps=sum(len(s.get('steps') or []) for s in cur['jobs'].values())
print(f"untouched coverage: all other steps byte-identical to {base_ref}; total steps now {n_steps}")
PY
then say "gate4 PASS: byte-extraction + coverage + untouched steps"; else fail "gate4"; fi

# ── gate 5 (stage-2 budget): inline run: lines ──
if python3 - "$REPO_ROOT" <<'PY'
import sys, pathlib, yaml
class L(yaml.SafeLoader): pass
def multi(loader, node, deep=False):
    seen=set(); res={}
    for k_node,v_node in node.value:
        k=loader.construct_object(k_node, deep=deep)
        if k in seen: raise yaml.constructor.ConstructorError(None,None,f"duplicate key {k!r}",node.start_mark)
        seen.add(k); res[k]=loader.construct_object(v_node, deep=deep)
    return res
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, multi)
root=pathlib.Path(sys.argv[1])
d=yaml.load((root/'.github/workflows/factory-teammate.yml').read_text(), Loader=L)
total=0; per=[]
for j,job in d['jobs'].items():
    for st in job.get('steps',[]):
        r=st.get('run')
        if r is None: continue
        n=len(r.rstrip('\n').split('\n')); total+=n; per.append((j,st.get('name'),n))
print(f"inline run: lines: {total} (budget ~120)")
for j,name,n in per:
    if n>1: print(f"  {n:4d}  {j}/{name}")
open('/tmp/ab_inline_count.txt','w').write(str(total))
sys.exit(0 if total<=125 else 1)
PY
then say "gate5 PASS: inline-sh budget"; else fail "gate5 (budget)"; fi

exit $rc
