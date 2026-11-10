import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const yaml = readFileSync(new URL('../gitlab/factory-teammate.yml', import.meta.url), 'utf8') + '\n';
function script(job, property = 'script') {
  const section = yaml.slice(yaml.indexOf(`${job}:\n`) + job.length + 2).split(/^\S/m)[0];
  const match = section.match(new RegExp(`^  ${property}:\\n    - \\|\\n((?:      .*\\n|\\n)+)`, 'm'));
  assert.ok(match, `${job}.${property} shell block`);
  return match[1].replace(/^      /gm, '');
}

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
  assert.equal(result.stderr.split('\n').filter(line => /^LIST .*page=2/.test(line)).length, 2);
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
