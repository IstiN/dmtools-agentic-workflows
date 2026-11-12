import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const yaml = readFileSync(new URL('../gitlab/factory-teammate.yml', import.meta.url), 'utf8') + '\n';
const smYaml = readFileSync(new URL('../gitlab/factory-sm.yml', import.meta.url), 'utf8') + '\n';
function script(job, property = 'script', source = yaml) {
  const section = source.slice(source.indexOf(`${job}:\n`) + job.length + 2).split(/^\S/m)[0];
  const match = section.match(new RegExp(`^  ${property}:\\n    - \\|\\n((?:      .*\\n|\\n)+)`, 'm'));
  assert.ok(match, `${job}.${property} shell block`);
  return match[1].replace(/^      /gm, '');
}

test('all native template shell blocks have valid Bash syntax', () => {
  for (const source of [yaml, smYaml]) {
    const blocks = [...source.matchAll(/^    - \|\n((?:      .*\n|\n)+)/gm)];
    assert.ok(blocks.length > 0);
    for (const [, block] of blocks) {
      const result = spawnSync('bash', ['-n'], {
        input: block.replace(/^      /gm, ''), encoding: 'utf8',
      });
      assert.equal(result.status, 0, result.stderr);
    }
  }
});

test('APT setup is opt-in, keeps the distro retry default and stops on update/install failures', () => {
  const teammate = script('.factory-teammate-install-tools');
  const sm = script('.factory-sm-install-tools', 'script', smYaml);
  assert.equal(teammate, sm, 'both templates must install the same prerequisites');
  const run = (env = {}) => spawnSync('bash', ['-c', `
    apt-get() {
      printf 'APT frontend=%s %s\\n' "\${DEBIAN_FRONTEND:-}" "$*" >&2
      case "$*" in
        *update) [ "\${FAIL_UPDATE:-}" != true ] ;;
        *install*) [ "\${FAIL_INSTALL:-}" != true ] ;;
        *) return 99 ;;
      esac
    }
    ${teammate}
    echo DONE
  `], { encoding: 'utf8', env: { PATH: process.env.PATH, ...env } });
  assert.equal(run().status, 0);
  assert.doesNotMatch(run().stderr, /APT /, 'prebuilt images do not invoke APT');
  const enabled = run({ DMTOOLS_GITLAB_INSTALL_TOOLS: 'true' });
  assert.equal(enabled.status, 0, enabled.stderr);
  assert.match(enabled.stderr, /APT::Update::Error-Mode=any update/);
  assert.match(enabled.stderr, /frontend=noninteractive install .*ca-certificates/);
  assert.doesNotMatch(enabled.stderr, /Acquire::Retries/, 'older apt must not be opted into retries (CVE-2026-109518)');
  for (const failure of ['FAIL_UPDATE', 'FAIL_INSTALL']) {
    const result = run({ DMTOOLS_GITLAB_INSTALL_TOOLS: 'true', [failure]: 'true' });
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout, /DONE/);
    if (failure === 'FAIL_UPDATE') assert.doesNotMatch(result.stderr, /install/);
    assert.equal(result.stderr.split('\n').filter(line => line.includes(' install ')).length,
      failure === 'FAIL_UPDATE' ? 0 : 1, 'no outer retry loop for permanent install failures');
  }
});

test('native SM resolves latest once and keeps explicit release tags pinned', () => {
  const sm = script('.factory-sm', 'script', smYaml);
  const resolution = sm.slice(sm.indexOf('resolve_tag() {'), sm.indexOf('\ninstall_dir='));
  const run = (agents, cli, extra = {}) => spawnSync('bash', ['-c', `
    set -euo pipefail
    gh() {
      printf 'GH %s\\n' "$*" >&2
      case "$2" in
        */releases/latest) printf '%s\\n' resolved-latest ;;
        */releases/tags/missing) return 1 ;;
        */releases/tags/*) printf '%s\\n' "\${2##*/}" ;;
        *) return 99 ;;
      esac
    }
    ${resolution}
    printf 'TAGS=%s,%s\\n' "$AGENTS_TAG" "$DMTOOLS_TAG"
  `], { encoding: 'utf8', env: {
    PATH: process.env.PATH, AGENTS_VERSION: agents, DMTOOLS_VERSION: cli, ...extra,
  } });
  const pinned = run('agents-test-pin', 'cli-test-pin');
  assert.equal(pinned.status, 0, pinned.stderr);
  assert.match(pinned.stdout, /TAGS=agents-test-pin,cli-test-pin/);
  assert.doesNotMatch(pinned.stderr, /releases\/latest/);
  const latest = run('latest', 'latest');
  assert.equal(latest.status, 0, latest.stderr);
  assert.match(latest.stdout, /TAGS=resolved-latest,resolved-latest/);
  for (const versions of [['', ''], [undefined, undefined]]) {
    const defaulted = run(...versions);
    assert.equal(defaulted.status, 0, defaulted.stderr);
    assert.match(defaulted.stdout, /TAGS=resolved-latest,resolved-latest/);
  }
  for (const versions of [['missing', 'latest'], ['latest', 'missing']]) {
    const failed = run(...versions);
    assert.notEqual(failed.status, 0);
    assert.doesNotMatch(failed.stdout, /TAGS=/);
  }
  assert.match(sm, /bash "\$install_dir\/install\.sh" "\$DMTOOLS_TAG"/);
  assert.match(sm, /DMTOOLS_PACK_REGISTRY="https:\/\/github.com\/IstiN\/dmtools-agents\/releases\/download\/\$AGENTS_TAG"/);
});

function scan(issues = [], mrs = [], options = {}) {
  return spawnSync('bash', ['-c', `
    curl() {
      case " $* " in
        *" --get "*)
          printf 'LIST %s\\n' "$*" >&2
          [ "\${FAIL_LIST:-}" != true ] || return 22
          case " $* " in
            *" page=2 "*) printf '%s' "$PAGE_TWO" ;;
            *"/merge_requests "*) printf '%s' "$MRS" ;;
            *) printf '%s' "$ISSUES" ;;
          esac ;;
        *"/related_merge_requests"*)
          [ "\${FAIL_RELATED:-}" != true ] || return 22
          printf '%s' "$RELATED" ;;
        *"/merge_requests/"[0-9]*) printf '{}' ;;
        *)
          local payload=""
          while [ "$#" -gt 0 ]; do
            case "$1" in --data) payload="$2"; shift 2 ;; *) shift ;; esac
          done
          printf 'DISPATCH %s\\n' "$(jq -ce '
            select((.ref | type == "string") and (.variables | type == "array")) |
            select(.variables | all(.[]; (.key | type == "string") and (.value | type == "string")))
          ' <<< "$payload")" >&2
          if [ "\${FAIL_DISPATCH:-}" = true ]; then
            printf '%s' '{"message":{"variables":["is invalid"]}}'
            return 22
          fi
          printf '%s' '{"id":123}' ;;
      esac
    }
    ${script('ai-teammate-scan')}
  `], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH, GITLAB_TOKEN: 'test-token', CI_PROJECT_ID: '123',
      CI_API_V4_URL: 'https://gitlab.example.com/api/v4', CI_DEFAULT_BRANCH: 'main',
      FACTORY_HOME_REF: 'a'.repeat(40), ISSUES: JSON.stringify(issues), MRS: JSON.stringify(mrs),
      RELATED: '[]', PAGE_TWO: '[]', ...options,
    },
  });
}

function requests(result) {
  assert.equal(result.status, 0, result.stderr);
  return result.stderr.split('\n').filter(line => line.startsWith('DISPATCH ')).map(line => {
    const body = JSON.parse(line.slice(9));
    assert.equal(body.ref, 'main');
    const variables = Object.fromEntries(body.variables.map(({ key, value }) => [key, value]));
    assert.equal(variables.FACTORY_HOME_REF, 'a'.repeat(40));
    assert.equal(variables.FACTORY_LEG, '', 'derive the leg from fresh state, not stale scan labels');
    assert.equal(variables.DMTOOLS_AI_TEAMMATE_SCAN, 'true');
    return variables;
  });
}

const issue = (iid, labels = ['agent:dev'], username = 'bot-123', name = 'ai-dev') => ({
  iid, state: 'opened', labels, assignees: [{ username, name }],
});

test('scans review and rework independently of agent:dev and assignment', () => {
  const result = scan([
    issue(17),
    issue(18, ['ai_developed', 'agent:rework', 'rework-round:1'], 'human', 'Human'),
    { ...issue(19, ['ai_developed', 'agent:review']), assignees: [] },
    issue(20, ['agent:dev'], 'other', 'Other'),
    issue(21, ['rework-round:1', 'ai_developed']),
  ]);
  assert.deepEqual(requests(result).map(v => [v.FACTORY_ISSUE, v.FACTORY_MR, v.DMTOOLS_AI_DEV_USERNAME]), [
    ['17', '', 'bot-123'], ['18', '', 'ai-dev'], ['19', '', 'ai-dev'],
  ]);
  assert.doesNotMatch(result.stderr, /labels=agent:dev/);
  assert.match(result.stdout, /Starting ai-teammate rework API pipeline for issues\/18/);
  assert.match(result.stdout, /Dispatched 3 ai-teammate pipelines/);
});

test('scans MR review/rework anchors, deduplicating related issue/MR queues', () => {
  const result = scan([issue(17, ['agent:rework'])], [
    issue(3, ['agent:rework']), issue(4, ['agent:review']), issue(5, ['agent:rework']), issue(6),
  ], { RELATED: '[{"iid":3,"project_id":123,"state":"opened"}]' });
  assert.deepEqual(requests(result).map(v => [v.FACTORY_ISSUE, v.FACTORY_MR]), [
    ['17', ''], ['', '4'], ['', '5'],
  ]);
  assert.match(result.stdout, /Skipping MR !3/);
});

test('skips held, closed, busy and answered development items without hiding rework', () => {
  const held = ['blocked', 'agent:skip', 'provider_quota', 'needs-human', 'ai_questions_asked',
    'status:In Development', 'status:In Review', 'status:In Rework'];
  const anchors = held.map((label, index) => issue(index + 1, ['agent:rework', label]));
  anchors.push({ ...issue(20, ['agent:review']), state: 'closed' },
    issue(21, ['ai_developed']), issue(22, ['agent:dev', 'ai_pr_reviewed']),
    issue(23, ['agent:review', 'agent:rework', 'ai_developed']));
  const result = scan(anchors);
  assert.deepEqual(requests(result).map(v => v.FACTORY_ISSUE), ['23']);
  assert.match(result.stdout, /Starting ai-teammate rework API pipeline for issues\/23/);
  assert.deepEqual(requests(scan([issue(24, ['agent:dev', 'ai_developed'])])).map(v => v.FACTORY_ISSUE), ['24']);
});

test('paginates both resource types and honors custom developer usernames', () => {
  const unassigned = Array.from({ length: 100 }, (_, index) => issue(index + 1, [], 'other', 'Other'));
  const result = scan(unassigned, unassigned, {
    DMTOOLS_AI_DEV_USERNAME: 'custom-bot',
    PAGE_TWO: JSON.stringify([issue(101, ['agent:dev'], 'custom-bot', 'Developer')]),
  });
  assert.deepEqual(requests(result).map(v => v.FACTORY_ISSUE), ['101']);
  assert.equal(result.stderr.split('\n').filter(line => /^LIST .*scope=all.*page=2/.test(line)).length, 2);
  assert.equal(requests(result)[0].DMTOOLS_AI_DEV_USERNAME, 'custom-bot');
  assert.deepEqual(requests(scan()), []);
});

test('API failures and malformed responses fail instead of reporting success', () => {
  for (const options of [{ FAIL_LIST: 'true' }, { FAIL_RELATED: 'true' },
    { FAIL_DISPATCH: 'true' }, { GITLAB_TOKEN: '' }, { RELATED: '{"message":"invalid"}' }]) {
    const result = scan([issue(17, ['agent:rework'])], [], options);
    assert.notEqual(result.status, 0, JSON.stringify(options));
    assert.doesNotMatch(result.stdout, /Dispatched \d+ ai-teammate pipelines/);
    if (options.FAIL_DISPATCH) assert.match(result.stdout, /variables.*is invalid/);
  }
  const malformed = scan({ message: 'invalid' });
  assert.notEqual(malformed.status, 0);
  assert.match(malformed.stderr, /Expected an anchor array/);
});

const main = script('.factory-teammate');
test('version knobs default at run time so caller YAML, project and pipeline pins win', () => {
  for (const [source, job] of [[yaml, '.factory-teammate'], [smYaml, '.factory-sm']]) {
    const section = source.slice(source.indexOf(`${job}:\n`)).split(/^\S/m)[1];
    const vars = section.slice(section.indexOf('  variables:\n'), section.indexOf('  script:\n'));
    assert.doesNotMatch(vars, /_VERSION:/, `${job} job variables would outrank caller top-level pins`);
  }
  const defaults = main.slice(main.indexOf('export AGENTS_VERSION='), main.indexOf('\n[[ "$FACTORY_HOME_REF"'));
  const run = env => spawnSync('bash', ['-c', `set -euo pipefail\n${defaults}\necho "$AGENTS_VERSION $DMTOOLS_VERSION $FA_VERSION"`],
    { encoding: 'utf8', env: { PATH: process.env.PATH, ...env } });
  assert.equal(run({}).stdout.trim(), 'latest latest latest');
  assert.equal(run({ AGENTS_VERSION: '', DMTOOLS_VERSION: '', FA_VERSION: '' }).stdout.trim(), 'latest latest latest');
  assert.equal(run({ AGENTS_VERSION: 'a1', DMTOOLS_VERSION: 'c1', FA_VERSION: 'f1' }).stdout.trim(), 'a1 c1 f1');
  assert.equal(run({ FA_VERSION: 'f1', FA_VERSION_MACHINE: 'm1' }).stdout.trim(), 'latest latest m1');
});

test('native teammate passes caller pins through the shared GitHub release resolvers', () => {
  const install = main.slice(main.indexOf('AGENTS_KNOB="$AGENTS_VERSION"'), main.indexOf('\nfor slot_number'));
  const root = fileURLToPath(new URL('../', import.meta.url));
  for (const pinned of [false, true]) {
    const dir = mkdtempSync(join(tmpdir(), 'gl-versions-'));
    try {
      mkdirSync(join(dir, 'workspace'));
      writeFileSync(join(dir, 'env'), '');
      writeFileSync(join(dir, 'path'), '');
      const result = spawnSync('bash', ['-c', `
        set -euo pipefail
        gh() {
          printf 'GH %s\\n' "$*" >&2
          case "$1 $2" in
            "release list") printf '%s\\n' agents-resolved-latest ;;
            "release view") printf '%s\\n' cli-resolved-latest ;;
            "release download")
              while [ "$#" -gt 0 ]; do
                if [ "$1" = --dir ]; then touch "$2/factory-setup-test.zip"; break; fi
                shift
              done ;;
            *) return 99 ;;
          esac
        }
        unzip() {
          mkdir -p "$4/setup" "$4/configs"
          touch "$4/setup/cache.sh" "$4/configs/pr_review.json"
          rm "$2"
          rmdir "\${2%/*}"
        }
        export -f gh unzip
        bash() {
          case "\${@: -1}" in
            */fetch-factory-setup.sh|*/resolve-dmtools-version.sh)
              helper="\${@: -1}"
              command bash -e "$SCRIPT_ROOT/scripts/\${helper##*/}" ;;
            */install-dmtools-cli.sh) printf 'CLI=%s\\n' "$DMTOOLS_VERSION" ;;
            */install-fa-cli.sh) printf 'FA=%s\\n' "$FA_VERSION" ;;
            *) return 99 ;;
          esac
        }
        ${main.slice(main.indexOf('import_env() {'), main.indexOf('\nAGENTS_KNOB='))}
        ${install}
        printf 'REGISTRY=%s\\n' "$DMTOOLS_PACK_REGISTRY"
      `], { encoding: 'utf8', env: {
        PATH: process.env.PATH, HOME: dir, RUNNER_TEMP: dir, SCRIPT_ROOT: root, GITHUB_ENV: join(dir, 'env'),
        GITHUB_PATH: join(dir, 'path'), GITHUB_WORKSPACE: join(dir, 'workspace'),
        AGENTS_VERSION: pinned ? 'agents-test-pin' : 'latest',
        DMTOOLS_VERSION: pinned ? 'cli-test-pin' : 'latest',
        FA_VERSION: pinned ? 'fa-test-pin' : 'latest',
      } });
      assert.equal(result.status, 0, result.stderr);
      assert.match(result.stdout, new RegExp(`CLI=${pinned ? 'cli-test-pin' : 'cli-resolved-latest'}`));
      assert.match(result.stdout, new RegExp(`FA=${pinned ? 'fa-test-pin' : 'latest'}`));
      assert.match(result.stdout, new RegExp(`REGISTRY=https://github.com/IstiN/dmtools-agents/releases/download/${pinned ? 'agents-test-pin' : 'agents-resolved-latest'}`));
      if (pinned) assert.doesNotMatch(result.stderr, /GH release (list|view)/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test('fresh routing honors an explicit SM rework leg without restarting implemented issues as dev', () => {
  const routing = main.slice(main.indexOf('leg="$FACTORY_LEG"'), main.indexOf('\nslot="$leg"'));
  const run = (labels, leg = '', resource = 'issues') => spawnSync('bash', ['-c', `
    set -euo pipefail
    ticket="$(jq -nc --argjson labels "$LABELS" '{labels:$labels,assignees:[{username:"bot"}]}')"
    resource="$RESOURCE"; anchor=gl-17
    ${routing}
    echo "LEG=$leg"
  `], { encoding: 'utf8', env: {
    PATH: process.env.PATH, FACTORY_LEG: leg, AGENT_HANDLE: 'bot', LABELS: JSON.stringify(labels), RESOURCE: resource,
  } });
  for (const [labels, leg, expected] of [
    [['rework-round:1', 'ai_developed'], 'rework', 'LEG=rework'],
    [['agent:rework', 'ai_developed'], '', 'LEG=rework'],
    [['agent:review', 'ai_developed'], '', 'LEG=review'],
    [['rework-round:1', 'ai_developed'], '', 'No eligible leg'],
    [[], '', 'LEG=dev'],
  ]) {
    const result = run(labels, leg);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes(expected), result.stdout);
  }
  assert.match(run([], '', 'merge_requests').stdout, /MR has no review\/rework queue label/);
});

test('failed rework retains its request label and original exit code', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gitlab-rework-'));
  try {
    const finalize = main.slice(main.indexOf('finalize() {'), main.indexOf('\nagent_result=1'));
    const result = spawnSync('bash', ['-c', `
      set -euo pipefail
      update_labels() { printf 'LABELS add=%s remove=%s\\n' "$1" "$2"; }
      note() { printf 'NOTE %s\\n' "$1"; }
      git() { :; }; cp() { :; }; rm() { :; }
      leg=rework; agent_result=42
      ${finalize}
      trap finalize EXIT
      exit 42
    `], { encoding: 'utf8', cwd: dir, env: {
      PATH: process.env.PATH, HOME: dir, RUNNER_TEMP: join(dir, 'session'), FA_LOG_FILE: join(dir, 'missing'),
      CI_RUN_URL: 'https://gitlab.example.com/jobs/1',
    } });
    assert.equal(result.status, 42, result.stderr);
    assert.match(result.stdout, /LABELS add=agent:rework remove=status:In Rework/);
    assert.doesNotMatch(result.stdout, /remove=.*agent:rework/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('cancelled rework retains its queue label and uses the developer token', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gitlab-cancel-'));
  try {
    mkdirSync(join(dir, '.dmtools'));
    writeFileSync(join(dir, '.dmtools/factory-state.json'), JSON.stringify({
      endpoint: 'issues/17', leg: 'rework', branch: 'fa-sess/gl-17',
    }));
    const result = spawnSync('bash', ['-c', `
      curl() { printf 'API %s\\n' "$*" >&2; }
      git() { :; }
      ${script('.factory-teammate', 'after_script')}
    `], { encoding: 'utf8', cwd: dir, env: {
      PATH: process.env.PATH, CI_JOB_STATUS: 'canceled',
      GITLAB_TOKEN: 'setup', GITLAB_DEV_TOKEN: 'developer', CI_PROJECT_ID: '123',
      CI_SERVER_URL: 'https://gitlab.example.com', CI_JOB_URL: 'https://gitlab.example.com/jobs/1',
    } });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /PRIVATE-TOKEN: developer/);
    assert.match(result.stderr, /remove_labels=status:In Rework/);
    assert.match(result.stderr, /add_labels=agent:rework/);
    assert.doesNotMatch(result.stderr, /remove_labels=.*agent:rework/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('successful rework, not failure cleanup, transitions the queue back to review', () => {
  const start = main.indexOf('if [[ "$leg" == dev || "$leg" == rework ]]; then\n  fresh_ticket=');
  const handoff = main.slice(start, main.indexOf('\nelse\n  verdict_file=', start)) + '\nfi';
  const result = spawnSync('bash', ['-c', `
    set -euo pipefail
    leg=rework; endpoint=issues/17
    api() { printf '%s' '{"labels":["agent:rework","rework-round:1"]}'; }
    update_labels() { printf 'LABELS add=%s remove=%s\\n' "$1" "$2"; }
    ${handoff}
  `], { encoding: 'utf8', env: { PATH: process.env.PATH } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /add=agent:review remove=agent:rework,/);
});

test('a changes-requested review queues rework together with its round marker', () => {
  const dir = mkdtempSync(join(tmpdir(), 'gitlab-review-'));
  try {
    mkdirSync(join(dir, 'outputs'));
    writeFileSync(join(dir, 'outputs/pr_review.json'), '{"decision":"request_changes"}');
    const start = main.indexOf('if [[ "$leg" == dev || "$leg" == rework ]]; then\n  fresh_ticket=');
    const handoff = main.slice(start, main.indexOf('\nif [[ "${DMTOOLS_GITLAB_FACTORY_HELPERS', start));
    for (const round of [0, 1, 2]) {
      const result = spawnSync('bash', ['-c', `
        set -euo pipefail
        leg=review; endpoint=issues/17; mr_number=3; reviewed_sha=head; MAX_AUTO_REWORK_ROUNDS=2
        api() {
          if [ "$1" = issues/17 ]; then printf '{"labels":["agent:review","rework-round:%s"]}' "$ROUND"
          else printf '%s' '{"sha":"head"}'; fi
        }
        update_labels() { printf 'LABELS add=%s remove=%s\\n' "$1" "$2"; }
        note() { printf 'NOTE %s\\n' "$1"; }
        ${handoff}
      `], { encoding: 'utf8', cwd: dir, env: { PATH: process.env.PATH, ROUND: String(round) } });
      assert.equal(result.status, 0, result.stderr);
      if (round < 2) {
        assert.ok(result.stdout.includes(`add=agent:rework,rework-round:${round + 1}`));
        assert.ok(result.stdout.includes(`remove=pr_approved,rework-round:${round}`));
      } else {
        assert.match(result.stdout, /add=needs-human remove=pr_approved/);
        assert.doesNotMatch(result.stdout, /add=agent:rework/);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

const helpers = { DMTOOLS_GITLAB_FACTORY_HELPERS: 'true' };

test('selects GITLAB_DEV_TOKEN for development legs and GITLAB_REVIEWER_TOKEN for review legs at runtime', () => {
  const selector = `${script('.factory-teammate-use-dev-token')}\n${script('.factory-teammate-select-token')}`;
  const run = (multi, labels, env = {}) => spawnSync('bash', ['-c', `
    set -euo pipefail
    curl() {
      case "$*" in
        */user) case "$*" in *review-token*) echo '{"username":"ai-reviewer"}' ;; *dev-token*) echo '{"username":"dev-bot"}' ;;
          *) echo '{"username":"setup-user"}' ;; esac ;;
        *) printf '%s' '{"labels":'"$LABELS"'}' ;;
      esac
    }
    ${selector}
    printf 'TOKEN=%s HANDLE=%s ROLE=%s\\n' "$GITLAB_TOKEN" "$AGENT_HANDLE" "$FACTORY_TEAMMATE_ROLE"
  `], {
    encoding: 'utf8',
    env: Object.fromEntries(Object.entries({
      PATH: process.env.PATH, FACTORY_ISSUE: '17', GITLAB_TOKEN: 'setup-token', GITLAB_DEV_TOKEN: 'dev-token',
      GITLAB_REVIEWER_TOKEN: 'review-token', AGENT_HANDLE: 'dev-bot',
      DMTOOLS_GITLAB_TEAMMATES: multi ? 'multiple' : 'single', ...(multi ? { GITLAB_REVIEWER_HANDLE: 'ai-reviewer' } : {}),
      CI_API_V4_URL: 'https://gitlab.example.com/api/v4', CI_PROJECT_ID: '1', LABELS: labels, ...env,
    }).filter(([, value]) => value !== undefined)),
  });
  const dev = run(true, '["agent:dev"]');
  assert.equal(dev.status, 0, dev.stderr);
  assert.match(dev.stdout, /Using GITLAB_DEV_TOKEN as GITLAB_TOKEN \(GitLab user: dev-bot\)/);
  assert.match(dev.stdout, /Development leg \(dev\): keeping the development token/);
  assert.match(dev.stdout, /TOKEN=dev-token HANDLE=dev-bot ROLE=dev/);
  assert.match(run(true, '["agent:dev","agent:rework"]').stdout, /TOKEN=dev-token HANDLE=dev-bot ROLE=dev/);
  const review = run(true, '["agent:dev","ai_developed","agent:review"]');
  assert.equal(review.status, 0, review.stderr);
  assert.match(review.stdout, /Review leg: using GITLAB_REVIEWER_TOKEN as GITLAB_TOKEN \(GitLab user: ai-reviewer\)/);
  assert.match(review.stdout, /TOKEN=review-token HANDLE=ai-reviewer ROLE=reviewer/);
  assert.match(run(true, '["agent:review","status:In Review"]').stdout, /TOKEN=dev-token .*ROLE=dev/);
  assert.match(run(true, '["agent:dev"]', { FACTORY_LEG: 'review' }).stdout, /TOKEN=review-token HANDLE=ai-reviewer ROLE=reviewer/);
  const missingReviewer = run(true, '["agent:review"]', { GITLAB_REVIEWER_TOKEN: undefined });
  assert.notEqual(missingReviewer.status, 0);
  assert.match(missingReviewer.stderr, /GITLAB_REVIEWER_TOKEN is required/);
  const missingDev = run(true, '["agent:dev"]', { GITLAB_DEV_TOKEN: undefined });
  assert.notEqual(missingDev.status, 0);
  assert.match(missingDev.stderr, /GITLAB_DEV_TOKEN is required in multi-teammate mode/);
  const singleSetup = run(false, '["agent:review"]', { GITLAB_DEV_TOKEN: undefined, GITLAB_REVIEWER_TOKEN: undefined });
  assert.equal(singleSetup.status, 0, singleSetup.stderr);
  assert.match(singleSetup.stdout, /Using GITLAB_TOKEN as GITLAB_TOKEN \(GitLab user: setup-user\)/);
  assert.match(singleSetup.stdout, /TOKEN=setup-token HANDLE=dev-bot ROLE=dev/);
  assert.match(run(false, '["agent:dev"]', { GITLAB_REVIEWER_TOKEN: undefined }).stdout, /TOKEN=dev-token HANDLE=dev-bot ROLE=dev/);
  assert.match(run(false, '["agent:review"]').stdout, /TOKEN=review-token HANDLE=dev-bot ROLE=reviewer/,
    'a configured reviewer token is used for review legs in single-teammate mode too');
});

test('removes runner job-token git rewrites, including included config, and checks GITLAB_TOKEN push access', () => {
  const auth = script('.factory-teammate-git-auth');
  const dir = mkdtempSync(join(tmpdir(), 'gl-auth-'));
  try {
    let runs = 0;
    const run = (access, scopes, { rewritten = true, remote = 'ok', env = helpers } = {}) => {
      const id = runs++;
      const repo = join(dir, `r${id}`);
      const included = join(dir, `r${id}.tmp-git-template-config`);
      const bare = join(dir, `remote${id}`);
      const setup = spawnSync('bash', ['-c', `
        set -e
        mkdir -p tpl && git init -q --template=tpl "${repo}" && cd "${repo}"
        git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
        if [ "${remote}" = ok ]; then git init -q --bare "${bare}.git"; fi
        if [ "${rewritten}" = true ]; then
          git config -f "${included}" url."https://gitlab-ci-token:SECRET@git.example.com/".insteadOf "https://git.example.com/"
          git config -f "${included}" credential."https://git.example.com".username gitlab-ci-token
          git config --local include.path "${included}"
          git config --local url."https://gitlab-ci-token:SECRET@git.example.com/".pushInsteadOf "${bare}"
          git config url."https://mirror.example.com/".insteadOf "git@mirror:"
        fi
        git remote add origin https://git.example.com/mobile/factory.git
      `], { cwd: dir, encoding: 'utf8', env: { PATH: process.env.PATH, HOME: dir, GIT_CONFIG_NOSYSTEM: '1' } });
      assert.equal(setup.status, 0, setup.stderr);
      return spawnSync('bash', ['-c', `
        set -euo pipefail
        curl() {
          case "$*" in
            *personal_access_tokens/self*) printf '{"scopes":[%s]}' "$SCOPES" ;;
            *) printf '{"permissions":{"project_access":{"access_level":%s},"group_access":null}}' "$ACCESS" ;;
          esac
        }
        ${auth}
        printf 'PUSH=%s\\n' "$(git remote get-url --push origin)"
        git config --list --show-origin
        test -d .git/info && echo INFO_OK
      `], {
        cwd: repo, encoding: 'utf8',
        env: { PATH: process.env.PATH, HOME: dir, GIT_CONFIG_NOSYSTEM: '1', GITLAB_TOKEN: 't',
          CI_API_V4_URL: 'https://git.example.com/api/v4', CI_PROJECT_ID: '1', CI_JOB_ID: '7', CI_PROJECT_URL: bare,
          ACCESS: String(access), SCOPES: scopes, ...env },
      });
    };
    const ok = run(40, '"api"');
    assert.equal(ok.status, 0, ok.stderr);
    assert.match(ok.stdout, /Removed CI job-token git config from .*tmp-git-template-config/);
    assert.match(ok.stdout, /PUSH=.*remote0\.git\n/);
    assert.doesNotMatch(ok.stdout, /gitlab-ci-token|SECRET/);
    assert.match(ok.stdout, /url\.https:\/\/mirror\.example\.com\/\.insteadof=git@mirror:/);
    assert.match(ok.stdout, /INFO_OK/);
    assert.match(ok.stdout, /GITLAB_TOKEN project access level: 40; scopes: api/);
    assert.match(ok.stdout, /Git push access check with GITLAB_TOKEN: OK/);
    assert.equal(ok.stderr, '');
    const weak = run(20, '"read_api","read_repository"');
    assert.equal(weak.status, 0, weak.stderr);
    assert.match(weak.stderr, /needs at least the Developer role/);
    assert.match(weak.stderr, /needs the api or write_repository scope/);
    const clean = run(40, '"api"', { rewritten: false });
    assert.equal(clean.status, 0, clean.stderr);
    assert.match(clean.stdout, /Git push URL: .*remote2\.git\n/);
    assert.doesNotMatch(clean.stdout, /Removed CI job-token/);
    const denied = run(40, '"api"', { remote: 'missing' });
    assert.equal(denied.status, 0, denied.stderr);
    assert.match(denied.stderr, /git push access check with GITLAB_TOKEN failed/);
    const optedOut = run(40, '"api"', { env: {} });
    assert.doesNotMatch(optedOut.stdout, /Removed CI job-token|Git push URL|INFO_OK/, 'git auth cleanup is opt-in');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('resolves AGENT_HANDLE from issue assignee display names before the parent runs', () => {
  const resolver = script('.factory-teammate-resolve-handle');
  const run = (handle, { fail = false, labels = '["agent:dev"]', env = helpers } = {}) => spawnSync('bash', ['-c', `
    set -euo pipefail
    curl() {
      if [ "\${FAIL:-}" = true ]; then return 22; fi
      case " $* " in *" PUT "*) printf 'PUT %s\\n' "$*" >&2; return 0 ;; esac
      printf '%s' '{"state":"opened","labels":'"$LABELS"',"assignees":[{"username":"project_297486_bot_abc","name":"ai-dev"},{"username":"human","name":"Human"}]}'
    }
    ${resolver}
    printf 'HANDLE=%s\\n' "$AGENT_HANDLE"
  `], {
    encoding: 'utf8',
    env: { PATH: process.env.PATH, FACTORY_ISSUE: '17', FACTORY_MR: '', GITLAB_TOKEN: 't', AGENT_HANDLE: handle,
      CI_API_V4_URL: 'https://gitlab.example.com/api/v4', CI_PROJECT_ID: '1', FAIL: String(fail), LABELS: labels, ...env },
  });
  const byName = run('ai-dev');
  assert.equal(byName.status, 0, byName.stderr);
  assert.match(byName.stdout, /Resolved AGENT_HANDLE ai-dev to assignee username project_297486_bot_abc/);
  assert.match(byName.stdout, /HANDLE=project_297486_bot_abc/);
  assert.match(byName.stdout, /labels: agent:dev/);
  assert.match(byName.stdout, /assignees: project_297486_bot_abc \(ai-dev\), human \(Human\)/);
  assert.doesNotMatch(byName.stderr, /PUT/);
  const stale = run('ai-dev', { labels: '["agent:dev","ai_developed"]' });
  assert.equal(stale.status, 0, stale.stderr);
  assert.match(stale.stderr, /PUT .*remove_labels=ai_developed/);
  assert.match(stale.stdout, /Cleared stale ai_developed from issue #17 before a new dev leg/);
  assert.doesNotMatch(run('ai-dev', { labels: '["agent:dev","ai_developed","agent:review"]' }).stderr, /PUT/);
  assert.doesNotMatch(run('ai-dev', { labels: '["ai_developed"]' }).stderr, /PUT/,
    'an implemented issue without a new development request keeps ai_developed');
  const byUsername = run('human');
  assert.match(byUsername.stdout, /HANDLE=human\n/);
  assert.doesNotMatch(byUsername.stdout, /Resolved/);
  const missing = run('nobody');
  assert.equal(missing.status, 0);
  assert.match(missing.stdout, /HANDLE=nobody/);
  assert.match(missing.stderr, /no assignee of issue #17 matches AGENT_HANDLE=nobody/);
  const failed = run('ai-dev', { fail: true });
  assert.equal(failed.status, 0);
  assert.match(failed.stdout, /HANDLE=ai-dev/);
  assert.match(failed.stderr, /unable to read issue #17/);
  assert.match(run('ai-dev', { env: {} }).stdout, /^HANDLE=ai-dev\n$/, 'handle resolution is opt-in');
});

test('fails dev legs that finish without an open merge request instead of queueing review', () => {
  const verify = main.slice(main.indexOf('if [[ "${DMTOOLS_GITLAB_FACTORY_HELPERS:-false}" == true && "$leg" == dev'));
  const run = (env) => spawnSync('bash', ['-c', `
    set -euo pipefail
    api() {
      printf 'API %s\\n' "$*" >&2
      case "$1" in
        issues/*/related_merge_requests*) printf '%s' "$RELATED" ;;
        merge_requests\\?*) printf '%s' "$BRANCH_MRS" ;;
        issues/17) printf '%s' "$ISSUE" ;;
        *) printf '{}' ;;
      esac
    }
    update_labels() { printf 'LABELS add=%s remove=%s\\n' "$1" "$2"; }
    note() { printf 'NOTE %s\\n' "$1"; }
    leg="$LEG"; number=17; anchor=gl-17; agent_result=0
    ${verify}
    echo DONE
  `], { encoding: 'utf8', env: { PATH: process.env.PATH, CI_PROJECT_ID: '5', BRANCH_MRS: '[]', LEG: 'dev',
    ISSUE: '{"labels":["agent:dev"]}', ...helpers, ...env } });
  const linked = run({ RELATED: '[{"iid":3,"state":"opened","project_id":5}]' });
  assert.equal(linked.status, 0, linked.stderr);
  assert.match(linked.stdout, /LABELS add=ai_developed remove=agent:dev\n/);
  assert.match(linked.stdout, /Issue #17 has 1 open merge request\(s\); labeled ai_developed and removed agent:dev\nDONE/);
  const byBranch = run({ RELATED: '[]', BRANCH_MRS: '[{"iid":9,"description":"Body"}]' });
  assert.equal(byBranch.status, 0, byBranch.stderr);
  assert.match(byBranch.stderr, /source_branch=ai%2Fgl-17/);
  assert.match(byBranch.stderr, /API merge_requests\/9 --request PUT --data-urlencode description=Closes #17\n\nBody/);
  assert.match(byBranch.stdout, /Linked merge request !9 to issue #17/);
  assert.match(byBranch.stdout, /LABELS add=ai_developed remove=agent:dev/);
  const missing = run({ RELATED: '[{"iid":4,"state":"closed","project_id":5},{"iid":2,"state":"opened","project_id":6}]' });
  assert.equal(missing.status, 1);
  assert.match(missing.stdout, /LABELS add=needs-human remove=agent:review/);
  assert.doesNotMatch(missing.stdout, /add=ai_developed|DONE/);
  assert.match(missing.stdout, /NOTE AI Teammate dev run finished without an open merge request/);
  const asked = run({ RELATED: '[]', ISSUE: '{"labels":["agent:dev","ai_questions_asked"]}' });
  assert.equal(asked.status, 0, asked.stderr);
  assert.match(asked.stdout, /waiting for answers \(ai_questions_asked\); no merge request expected yet/);
  assert.doesNotMatch(asked.stdout, /needs-human|ai_developed/);
  for (const env of [{ LEG: 'review', RELATED: '[]' }, { RELATED: '[]', DMTOOLS_GITLAB_FACTORY_HELPERS: '' }]) {
    const skipped = run(env);
    assert.equal(skipped.status, 0, skipped.stderr);
    assert.doesNotMatch(skipped.stderr, /API/);
  }
});

test('closes rework/review cycles on the linked issue and MR', () => {
  const close = script('.factory-teammate-close-cycle');
  assert.match(yaml, /    - !reference \[\.factory-teammate-close-cycle, script\]\n  artifacts:/);
  const run = (state, env = {}, files = {}) => {
    const dir = mkdtempSync(join(tmpdir(), 'gl-close-'));
    try {
      mkdirSync(join(dir, '.dmtools'));
      mkdirSync(join(dir, 'outputs'));
      if (state) writeFileSync(join(dir, '.dmtools/factory-state.json'), JSON.stringify(state));
      for (const [name, content] of Object.entries(files)) writeFileSync(join(dir, name), content);
      return spawnSync('bash', ['-c', `
        curl() {
          local method=GET token="" data="" url="\${@: -1}"
          while [ "$#" -gt 1 ]; do
            case "$1" in
              --request) method="$2"; shift 2 ;;
              --header) token="\${2#PRIVATE-TOKEN: }"; shift 2 ;;
              --data-urlencode) data="$data $2"; shift 2 ;;
              *) shift ;;
            esac
          done
          printf 'CALL %s %s %s%s\\n' "$token" "$method" "\${url#https://gl/api/v4/projects/5/}" "$data" >&2
          [ "$method" = GET ] || { printf '{}'; return 0; }
          case "$url" in
            */related_merge_requests*) printf '%s' "\${RELATED:-[]}" ;;
            */merge_requests/*) printf '%s' "\${MR:-null}" ;;
            */issues/*) printf '%s' "\${ISSUE:-null}" ;;
          esac
        }
        ${close}
        echo DONE
      `], { cwd: dir, encoding: 'utf8', env: { PATH: process.env.PATH, CI_API_V4_URL: 'https://gl/api/v4',
        CI_PROJECT_ID: '5', GITLAB_TOKEN: 'project', GITLAB_DEV_TOKEN: 'dev', ...helpers, ...env } });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };
  const calls = (result) => result.stderr.split('\n').filter(line => line.startsWith('CALL '));
  const writes = (result) => calls(result).filter(line => / PUT /.test(line));

  const related = JSON.stringify([
    { iid: 8, state: 'opened', project_id: 5, source_branch: 'feature' },
    { iid: 9, state: 'opened', project_id: 5, source_branch: 'ai/gl-17' },
    { iid: 10, state: 'merged', project_id: 5, source_branch: 'ai/gl-17' },
  ]);
  const rework = run({ endpoint: 'issues/17', leg: 'rework' }, { CI_JOB_STATUS: 'success', RELATED: related });
  assert.equal(rework.status, 0, rework.stderr);
  assert.deepEqual(writes(rework), [
    'CALL dev PUT issues/17 add_labels= remove_labels=agent:rework,status:In Rework',
    'CALL dev PUT merge_requests/9 add_labels= remove_labels=agent:rework,status:In Rework',
    'CALL dev PUT merge_requests/9 add_labels= remove_labels=ai_validated,ai_validating,validation_failed,ai_pr_reviewed,pr_approved',
  ]);

  for (const status of ['failed', 'canceled']) {
    const failedRework = run({ endpoint: 'merge_requests/9', leg: 'rework' },
      { CI_JOB_STATUS: status, MR: '{"description":"Fixes #17\\n\\nBody","source_branch":"x"}' });
    assert.equal(failedRework.status, 0, failedRework.stderr);
    assert.deepEqual(writes(failedRework), [
      'CALL dev PUT issues/17 add_labels= remove_labels=status:In Rework',
      'CALL dev PUT merge_requests/9 add_labels= remove_labels=status:In Rework',
    ], `${status} rework keeps its agent:rework request`);
  }

  const approve = run({ endpoint: 'issues/17', leg: 'review' },
    { CI_JOB_STATUS: 'success', GITLAB_REVIEWER_TOKEN: 'reviewer', ISSUE: '{"labels":["rework-round:2","pr_approved"]}' },
    { '.dmtools/merge-request.json': '{"iid":9}', 'outputs/pr_review.json': '{"decision":"approve"}' });
  assert.equal(approve.status, 0, approve.stderr);
  assert.ok(calls(approve).every(line => line.startsWith('CALL reviewer ')), 'review cleanup must use the reviewer token');
  assert.deepEqual(writes(approve), [
    'CALL reviewer PUT issues/17 add_labels= remove_labels=agent:review,status:In Review',
    'CALL reviewer PUT merge_requests/9 add_labels= remove_labels=agent:review,status:In Review',
    'CALL reviewer PUT merge_requests/9 add_labels=ai_pr_reviewed remove_labels=',
    'CALL reviewer PUT issues/17 add_labels= remove_labels=rework-round:2,needs-human',
    'CALL reviewer PUT merge_requests/9 add_labels= remove_labels=needs-human',
  ]);

  const changes = run({ endpoint: 'merge_requests/9', leg: 'review' },
    { CI_JOB_STATUS: 'success', MR: '{"description":"","source_branch":"ai/gl-17"}' },
    { 'outputs/pr_review.json': '{"decision":"REQUEST_CHANGES"}' });
  assert.deepEqual(writes(changes), [
    'CALL dev PUT issues/17 add_labels= remove_labels=agent:review,status:In Review',
    'CALL dev PUT merge_requests/9 add_labels= remove_labels=agent:review,status:In Review',
    'CALL dev PUT merge_requests/9 add_labels=ai_pr_reviewed remove_labels=',
  ]);

  const failedReview = run({ endpoint: 'merge_requests/9', leg: 'review' },
    { CI_JOB_STATUS: 'failed', MR: '{"description":"","source_branch":"other"}' });
  assert.deepEqual(writes(failedReview), [
    'CALL dev PUT merge_requests/9 add_labels= remove_labels=agent:review,status:In Review',
  ]);

  for (const result of [run({ endpoint: 'issues/17', leg: 'dev' }, { CI_JOB_STATUS: 'success' }), run(null)]) {
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(writes(result), []);
    assert.match(result.stdout, /DONE/);
  }
  const optedOut = run({ endpoint: 'issues/17', leg: 'rework' },
    { CI_JOB_STATUS: 'success', RELATED: related, DMTOOLS_GITLAB_FACTORY_HELPERS: '' });
  assert.equal(optedOut.status, 0, optedOut.stderr);
  assert.deepEqual(calls(optedOut), [], 'linked cycle cleanup is opt-in');
});

const scanScript = script('ai-teammate-scan');
const scanEnv = { PATH: process.env.PATH, GITLAB_TOKEN: 't', CI_API_V4_URL: 'https://gl/api/v4', CI_PROJECT_ID: '5',
  CI_DEFAULT_BRANCH: 'main', FACTORY_HOME_REF: 'a'.repeat(40) };

test('scan syncs MR validation labels from the head pipeline', () => {
  const run = (mrs, extraEnv = {}) => spawnSync('bash', ['-c', `
    curl() {
      case " $* " in
        *"/merge_requests"*)
          case " $* " in
            *" --request PUT "*)
              printf 'PUT %s\\n' "$*" >&2
              if [ "\${FAIL_MR_PUT:-}" = true ]; then return 22; fi; printf '{}' ;;
            *" --get "*) case " $* " in *" page=1 "*) printf '%s' "$MRS" ;; *) printf '[]' ;; esac ;;
            *) url="\${@: -1}"; printf '%s' "$MRS" | jq -c --arg iid "\${url##*/}" 'first(.[] | select((.iid | tostring) == $iid))' ;;
          esac
          ;;
        *) printf '[]' ;;
      esac
    }
    ${scanScript}
  `], { encoding: 'utf8', env: { ...scanEnv, MRS: JSON.stringify(mrs), ...extraEnv } });
  const mr = (iid, status, labels = [], extra = {}) => ({
    iid, sha: 'head', labels, draft: false, head_pipeline: status ? { status, sha: 'head' } : null, ...extra,
  });
  const result = run([
    mr(1, 'success', ['ai_validating']),
    mr(2, 'failed', ['ai_validated']),
    mr(3, 'running', ['validation_failed']),
    mr(4, 'success', ['ai_validated']),
    mr(5, null, ['ai_validated']),
    mr(6, 'success', ['ai_validated'], { head_pipeline: { status: 'success', sha: 'old' } }),
    mr(7, 'success', [], { draft: true }),
    mr(8, 'pending', []),
  ]);
  assert.equal(result.status, 0, result.stderr);
  const puts = result.stderr.split('\n').filter(line => line.startsWith('PUT '));
  const put = (iid) => puts.find(line => line.endsWith(`/merge_requests/${iid}`));
  assert.match(put(1) ?? '', /add_labels=ai_validated .*remove_labels=ai_validating /);
  assert.match(put(2) ?? '', /add_labels=validation_failed .*remove_labels=ai_validated /);
  assert.match(put(3) ?? '', /add_labels=ai_validating .*remove_labels=validation_failed /);
  assert.equal(put(4), undefined, 'labels already in sync must not be rewritten');
  assert.match(put(5) ?? '', /add_labels= .*remove_labels=ai_validated /);
  assert.match(put(6) ?? '', /add_labels= .*remove_labels=ai_validated /, 'a moved head voids ai_validated');
  assert.equal(put(7), undefined, 'draft MRs are not validated');
  assert.match(put(8) ?? '', /add_labels=ai_validating /);
  assert.match(result.stdout, /Updated validation labels on 6 merge request\(s\)/);

  const failing = run([mr(1, 'success')], { FAIL_MR_PUT: 'true' });
  assert.equal(failing.status, 0, 'validation label errors must not fail the scan');
  assert.match(failing.stderr, /unable to update validation labels on MR !1/);
});

test('scan arms agent:rework once per red machine-authored MR head and escalates instead of looping', () => {
  const run = (mrs, extraEnv = {}) => spawnSync('bash', ['-c', `
    curl() {
      local method=GET url="\${@: -1}" data=""
      for arg in "$@"; do
        case "$arg" in PUT|POST) method="$arg" ;; add_labels=*|body=*) data="$data $arg" ;; esac
      done
      case "$method $url" in
        "GET https://gl/api/v4/projects/5/issues") printf '[]' ;;
        "GET https://gl/api/v4/projects/5/issues/"*)
          printf '%s' "$ISSUES" | jq -c --arg iid "\${url##*/}" 'first(.[] | select((.iid | tostring) == $iid)) // error("missing")' ;;
        "GET https://gl/api/v4/projects/5/merge_requests")
          case " $* " in *" page=1 "*) printf '%s' "$MRS" ;; *) printf '[]' ;; esac ;;
        "GET https://gl/api/v4/projects/5/merge_requests/"*/notes)
          printf 'NOTES %s\\n' "$*" >&2
          if [ "\${FAIL_NOTES:-}" = true ]; then return 22; fi
          note_data="$NOTES"
          case " $* " in
            *" page=2 "*)
              if [ "\${FAIL_NOTES_PAGE_TWO:-}" = true ]; then return 22; fi
              note_data="$NOTES_PAGE_TWO" ;;
          esac
          iid="\${url%/notes}"; printf '%s' "$note_data" | jq -c --arg iid "\${iid##*/}" '.[$iid] // []' ;;
        "GET https://gl/api/v4/projects/5/merge_requests/"*)
          printf '%s' "$MRS" | jq -c --arg iid "\${url##*/}" 'first(.[] | select((.iid | tostring) == $iid))' ;;
        *) printf 'WRITE %s %s%s\\n' "$method" "\${url#https://gl/api/v4/projects/5/}" "$data" >&2; printf '{}' ;;
      esac
    }
    ${scanScript}
  `], { encoding: 'utf8', env: { ...scanEnv, SM_MACHINE_AUTHOR: 'ai-teammate', MRS: JSON.stringify(mrs),
    ISSUES: '[]', NOTES: '{}', NOTES_PAGE_TWO: '{}', ...extraEnv } });
  const mr = (iid, extra = {}) => ({
    iid, sha: `head${iid}`, labels: ['validation_failed'], draft: false, author: { username: 'ai-teammate' },
    description: '', source_branch: `feature-${iid}`, head_pipeline: { status: 'failed', sha: `head${iid}` }, ...extra,
  });
  const writes = (stderr) => stderr.split('\n').filter(line => line.startsWith('WRITE '));

  const armed = run([
    mr(1, { description: 'Closes #11' }),
    mr(2),
    mr(3, { author: { username: 'guest' } }),
    mr(4, { labels: ['validation_failed', 'agent:rework'] }),
    mr(5, { labels: ['validation_failed', 'needs-human'] }),
    mr(6, { head_pipeline: { status: 'failed', sha: 'old' } }),
    mr(7, { head_pipeline: { status: 'success', sha: 'head7' }, labels: ['ai_validated'] }),
    mr(8, { source_branch: 'ai/gl-18' }),
    mr(9, { author: { username: 'project_bot_1', name: 'ai-dev' } }),
  ], { ISSUES: JSON.stringify([
    { iid: 11, state: 'opened', labels: ['ai_developed'] },
    { iid: 18, state: 'opened', labels: ['status:In Rework'] },
  ]) });
  assert.equal(armed.status, 0, armed.stderr);
  const armWrites = writes(armed.stderr);
  assert.ok(armWrites.includes('WRITE PUT issues/11 add_labels=agent:rework'), 'linked issue is armed for the scanner');
  assert.ok(armWrites.includes('WRITE PUT merge_requests/2 add_labels=agent:rework'), 'unlinked MR is armed');
  assert.ok(armWrites.includes('WRITE PUT merge_requests/9 add_labels=agent:rework'), 'dev account matched by display name');
  assert.ok(armWrites.some(line => /^WRITE POST merge_requests\/1\/notes body=.*dmtools:red-ci-arm head=head1 /.test(line)));
  for (const skipped of [3, 4, 5, 6, 7, 8]) {
    assert.ok(!armWrites.some(line => line.includes('add_labels=agent:rework') &&
      (line.includes(`merge_requests/${skipped} `) || (skipped === 8 && line.includes('issues/18')))), `MR !${skipped} must not be armed`);
  }
  assert.match(armed.stdout, /Armed agent:rework for red CI on 3 merge request\(s\)/);

  const marker = (kind, head) => ({ body: `x <!-- dmtools:${kind} head=${head} -->` });
  const escalated = run([mr(1, { description: 'Fixes #11' }), mr(2), mr(3)], {
    ISSUES: JSON.stringify([{ iid: 11, state: 'opened', labels: [] }]),
    NOTES: JSON.stringify({
      1: [marker('red-ci-arm', 'head1')],
      2: [marker('red-ci-arm', 'head2'), marker('red-ci-withheld', 'head2')],
      3: [marker('red-ci-arm', 'older-head')],
    }),
  });
  assert.equal(escalated.status, 0, escalated.stderr);
  const escWrites = writes(escalated.stderr);
  assert.ok(escWrites.includes('WRITE PUT issues/11 add_labels=needs-human'));
  assert.ok(escWrites.includes('WRITE PUT merge_requests/1 add_labels=needs-human'));
  assert.ok(escWrites.some(line => /^WRITE POST merge_requests\/1\/notes body=.*dmtools:red-ci-withheld head=head1 /.test(line)));
  assert.ok(!escWrites.some(line => line.includes('merge_requests/2')), 'escalation is posted once per head');
  assert.ok(escWrites.includes('WRITE PUT merge_requests/3 add_labels=agent:rework'), 'a new head restarts the budget');
  assert.ok(!escWrites.some(line => line.includes('agent:rework') && line.includes('/1')), 'no re-arm on an unchanged head');

  const noNotes = run([mr(2)], { FAIL_NOTES: 'true' });
  assert.equal(noNotes.status, 0, 'red-CI arm errors must not fail the scan');
  assert.ok(!writes(noNotes.stderr).some(line => line.includes('agent:rework')), 'unknown marker history fails closed');
  assert.match(noNotes.stderr, /unable to read notes of red MR !2/);

  const recentNotes = Array.from({ length: 100 }, () => ({ body: 'unrelated note' }));
  const oldMarker = run([mr(2)], {
    NOTES: JSON.stringify({ 2: recentNotes }),
    NOTES_PAGE_TWO: JSON.stringify({ 2: [marker('red-ci-arm', 'head2')] }),
  });
  assert.equal(oldMarker.status, 0, oldMarker.stderr);
  assert.match(oldMarker.stderr, /NOTES .*page=2/);
  assert.ok(writes(oldMarker.stderr).includes('WRITE PUT merge_requests/2 add_labels=needs-human'));
  assert.ok(!writes(oldMarker.stderr).some(line => line.includes('add_labels=agent:rework')));
  const laterPageFailure = run([mr(2)], {
    NOTES: JSON.stringify({ 2: recentNotes }), FAIL_NOTES_PAGE_TWO: 'true',
  });
  assert.equal(laterPageFailure.status, 0, laterPageFailure.stderr);
  assert.match(laterPageFailure.stderr, /unable to read notes of red MR !2/);
  assert.ok(!writes(laterPageFailure.stderr).some(line => /agent:rework|needs-human/.test(line)));
  const invalidNotes = run([mr(2)], { NOTES: '{"2":{"message":"invalid"}}' });
  assert.equal(invalidNotes.status, 0, invalidNotes.stderr);
  assert.match(invalidNotes.stderr, /invalid notes of red MR !2/);
  assert.ok(!writes(invalidNotes.stderr).some(line => /agent:rework|needs-human/.test(line)));

  for (const label of ['status:In Development', 'status:In Review', 'ai_questions_asked']) {
    for (const linked of [false, true]) {
      const busy = run([mr(2, linked ? { description: 'Closes #11' } : { labels: [label] })], {
        ISSUES: JSON.stringify([{ iid: 11, state: 'opened', labels: [label] }]),
      });
      assert.equal(busy.status, 0, busy.stderr);
      assert.ok(!writes(busy.stderr).some(line => /agent:rework|needs-human/.test(line)),
        `${label} on the ${linked ? 'linked issue' : 'MR'} must prevent red-CI arming`);
    }
  }
});
