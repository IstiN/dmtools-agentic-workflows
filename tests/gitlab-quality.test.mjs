import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const yaml = readFileSync(new URL('../gitlab/factory-quality.yml', import.meta.url), 'utf8');
const presets = ['crap4js', 'crap4dart', 'crap4java', 'crap4py', 'crap4go'];
function gate(preset) {
  const job = `.factory-quality-${preset}`;
  const section = yaml.slice(yaml.indexOf(`${job}:\n`) + job.length + 2).split(/^\S/m)[0];
  assert.match(section, /^  before_script: \[\]\n  after_script: \[\]\n/, `${job} clears inherited hooks`);
  const match = section.match(/^  script:\n    - \|\n((?:      .*\n|\n)+)/m);
  assert.ok(match, `${job}.script shell block`);
  return match[1].replace(/^      /gm, '');
}
const tool = (path, body) => {
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
};
const withDir = (prefix, fn) => {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  try { fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
};

test('every quality gate is a hidden job with valid Bash', () => {
  for (const preset of presets) {
    const result = spawnSync('bash', ['-n'], { input: gate(preset), encoding: 'utf8' });
    assert.equal(result.status, 0, `${preset}: ${result.stderr}`);
  }
  const keys = yaml.match(/^[^\s#][^:]*:/gm);
  assert.deepEqual(keys, presets.map((preset) => `.factory-quality-${preset}:`));
});

test('every gate fails if the selected stack does not match the repository', () => {
  withDir('gitlab-quality-', (dir) => {
    for (const preset of presets) {
      const result = spawnSync('bash', ['-e', '-c', gate(preset)], { cwd: dir, encoding: 'utf8' });
      assert.equal(result.status, 1, preset);
      assert.match(result.stderr, /Configured quality gate does not match this repository/, preset);
    }
  });
});

test('JavaScript gate fails without coverage and propagates analyzer failures', () => {
  withDir('gitlab-quality-js-', (dir) => {
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ scripts: { test: 'node --test' } }));
    tool(join(dir, 'bin/npm'), 'exit 0');
    tool(join(dir, 'bin/npx'), `if [ "$1" = c8 ]; then
  if [ "\${OMIT_COVERAGE:-}" != 1 ]; then mkdir -p coverage; echo '{}' > coverage/coverage-final.json; fi
  exit 0
fi
exit "\${GATE_EXIT:-0}"`);
    const env = { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}` };
    const run = (extra = {}) => spawnSync('bash', ['-e', '-c', gate('crap4js')], { cwd: dir, env: { ...env, ...extra }, encoding: 'utf8' });
    const missing = run({ OMIT_COVERAGE: '1' });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Missing JavaScript coverage data/);
    assert.equal(run({ GATE_EXIT: '2' }).status, 2);
    const passing = run();
    assert.equal(passing.status, 0, passing.stderr);
  });
});

function dartFixture(dir, pubspec) {
  const bin = join(dir, 'bin');
  const fx = join(dir, 'fx');
  const project = join(dir, 'project');
  mkdirSync(join(project, 'test'), { recursive: true });
  writeFileSync(join(project, 'pubspec.yaml'), pubspec);
  writeFileSync(join(project, 'test/example_test.dart'), '');
  tool(join(fx, 'flutter/bin/flutter'), `echo "flutter $*" >> "$TEST_LOG"
if [ "$1" = test ] && [ "\${OMIT_COVERAGE:-}" != 1 ]; then mkdir -p coverage; echo 'SF:lib/example.dart' > coverage/lcov.info; fi`);
  tool(join(fx, 'flutter/bin/cache/dart-sdk/bin/dart'), `echo "dart $*" >> "$TEST_LOG"
if [ "$1" = format ]; then exit "\${FORMAT_EXIT:-0}"; fi
if [ "$1 $2" = "pub global" ] && [ "$3" = run ] && [ "$4" = coverage:format_coverage ]; then mkdir -p coverage; echo 'SF:lib/example.dart' > coverage/lcov.info; fi
if [ "$4" = crap4dart:crap4dart ]; then exit "\${GATE_EXIT:-0}"; fi`);
  const packed = spawnSync('tar', ['-cJf', join(fx, 'flutter.txz'), '-C', fx, 'flutter'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);
  writeFileSync(join(fx, 'releases.json'), JSON.stringify({
    base_url: 'https://storage.example/releases',
    current_release: { stable: 'stable-hash', beta: 'beta-hash' },
    releases: [
      { hash: 'stable-hash', channel: 'stable', archive: 'stable/linux/flutter-stable.tar.xz' },
      { hash: 'beta-hash', channel: 'beta', archive: 'beta/linux/flutter-beta.tar.xz' },
    ],
  }));
  tool(join(bin, 'uname'), 'echo x86_64');
  tool(join(bin, 'apt-get'), 'echo "apt-get $*" >> "$TEST_LOG"');
  tool(join(bin, 'git'), 'echo "git $*" >> "$TEST_LOG"');
  tool(join(bin, 'curl'), `for arg; do url="$arg"; done
echo "curl $url" >> "$TEST_LOG"
case "$url" in
  https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json) cat "${fx}/releases.json" ;;
  https://storage.example/releases/*/linux/flutter-*.tar.xz) cat "${fx}/flutter.txz" ;;
  *) exit 22 ;;
esac`);
  const env = { ...process.env, HOME: dir, PATH: `${bin}:${process.env.PATH}`, TEST_LOG: join(dir, 'calls') };
  const run = (extra = {}) =>
    spawnSync('bash', ['-c', gate('crap4dart')], { cwd: project, env: { ...env, ...extra }, encoding: 'utf8' });
  const calls = () => readFileSync(join(dir, 'calls'), 'utf8');
  return { run, calls, reset: () => rmSync(join(dir, 'calls'), { force: true }) };
}

test('Dart gate installs official Flutter and runs Flutter coverage with the Dart analyzer', () => {
  withDir('gitlab-quality-dart-', (dir) => {
    const { run, calls, reset } = dartFixture(dir, 'environment:\n  sdk: ^3.13.7\ndependencies:\n  flutter:\n    sdk: flutter\n');
    const missing = run({ OMIT_COVERAGE: '1' });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Missing Dart coverage data/);
    assert.equal(run({ GATE_EXIT: '2' }).status, 2);
    const unformatted = run({ FORMAT_EXIT: '1' });
    assert.equal(unformatted.status, 1);
    assert.match(unformatted.stderr, /Dart formatting check failed: run 'dart format \.'/);
    reset();
    const passing = run();
    assert.equal(passing.status, 0, passing.stderr);
    const log = calls();
    assert.match(log, /apt-get .*install -y --no-install-recommends ca-certificates curl git jq unzip xz-utils/);
    assert.match(log, /curl https:\/\/storage\.example\/releases\/stable\/linux\/flutter-stable\.tar\.xz/);
    assert.match(log, /flutter pub get/);
    assert.match(log, /flutter analyze/);
    assert.match(log, /flutter test --coverage/);
    assert.match(log, /dart pub global run crap4dart:crap4dart analyze --lcov coverage\/lcov\.info/);
  });
});

test('Dart gate honors the Flutter channel and can force plain Dart commands', () => {
  withDir('gitlab-quality-dart-', (dir) => {
    const { run, calls, reset } = dartFixture(dir, 'dependencies:\n  flutter:\n    sdk: flutter\n');
    const beta = run({ DMTOOLS_QUALITY_FLUTTER_VERSION: 'beta' });
    assert.equal(beta.status, 0, beta.stderr);
    assert.match(calls(), /flutter-beta\.tar\.xz/);
    reset();
    const dartOnly = run({ DMTOOLS_QUALITY_FLUTTER_COMMANDS: 'false' });
    assert.equal(dartOnly.status, 0, dartOnly.stderr);
    assert.match(calls(), /dart pub get/);
    assert.match(calls(), /dart analyze/);
    assert.match(calls(), /dart test --coverage=coverage/);
    assert.doesNotMatch(calls(), /flutter (pub get|analyze|test)/);
  });
});

test('Python gate handles test outcomes and propagates analyzer failures', () => {
  withDir('gitlab-quality-python-', (dir) => {
    writeFileSync(join(dir, 'example.py'), 'value = 1\n');
    tool(join(dir, 'bin/python'), 'exit 0');
    tool(join(dir, 'bin/pip'), 'exit 0');
    tool(join(dir, 'bin/coverage'), `if [ "$1" = run ]; then exit "\${TEST_EXIT:-0}"; fi
if [ "$1" = json ]; then echo '{}' > coverage.json; fi`);
    tool(join(dir, 'bin/crap4py'), 'echo "$*" >> "$TEST_LOG"\nexit "${GATE_EXIT:-0}"');
    const env = { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, TEST_LOG: join(dir, 'calls') };
    const run = (extra = {}) => spawnSync('bash', ['-e', '-c', gate('crap4py')], { cwd: dir, env: { ...env, ...extra }, encoding: 'utf8' });
    const noTests = run({ TEST_EXIT: '5' });
    assert.equal(noTests.status, 0, noTests.stderr);
    assert.match(noTests.stdout, /No tests collected/);
    assert.equal(run({ TEST_EXIT: '1' }).status, 1);
    assert.equal(run({ GATE_EXIT: '2' }).status, 2);
    const passing = run();
    assert.equal(passing.status, 0, passing.stderr);
    assert.match(readFileSync(join(dir, 'calls'), 'utf8'), /--coverage coverage\.json/);
  });
});

test('Go gate builds the analyzer from its module and propagates gate failures', () => {
  withDir('gitlab-quality-go-', (dir) => {
    writeFileSync(join(dir, 'go.mod'), 'module example\n');
    writeFileSync(join(dir, 'main.go'), 'package main\n');
    writeFileSync(join(dir, 'main_test.go'), 'package main\n');
    tool(join(dir, 'bin/gofmt'), 'exit 0');
    tool(join(dir, 'bin/git'), 'mkdir -p "$5"');
    tool(join(dir, 'bin/go'), `echo "$*" >> "$TEST_LOG"
case "$1" in
  test) if [ "\${OMIT_COVERAGE:-}" != 1 ]; then echo 'mode: atomic' > coverage.out; fi ;;
  build) printf '#!/bin/sh\\nexit "\${GATE_EXIT:-0}"\\n' > "$3"; chmod +x "$3" ;;
esac`);
    const env = { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, TMPDIR: dir, TEST_LOG: join(dir, 'calls') };
    const run = (extra = {}) => spawnSync('bash', ['-e', '-c', gate('crap4go')], { cwd: dir, env: { ...env, ...extra }, encoding: 'utf8' });
    const missing = run({ OMIT_COVERAGE: '1' });
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Missing Go coverage data/);
    assert.equal(run({ GATE_EXIT: '2' }).status, 2);
    const passing = run();
    assert.equal(passing.status, 0, passing.stderr);
    const calls = readFileSync(join(dir, 'calls'), 'utf8');
    assert.match(calls, /build -o .*crap4go/);
    assert.doesNotMatch(calls, /install .*crap4go/);
  });
});

test('Java gate analyzes Maven modules and fails if any module lacks JaCoCo coverage', () => {
  withDir('gitlab-quality-java-', (dir) => {
    mkdirSync(join(dir, 'module/src/main/java'), { recursive: true });
    writeFileSync(join(dir, 'pom.xml'), '<project/>');
    writeFileSync(join(dir, 'module/pom.xml'), '<project/>');
    writeFileSync(join(dir, 'module/src/main/java/App.java'), 'class App {}');
    tool(join(dir, 'bin/apt-get'), 'exit 0');
    tool(join(dir, 'bin/git'), 'mkdir -p "$5"');
    tool(join(dir, 'bin/mvn'), 'mkdir -p "$(dirname "$3")/target"\ntouch "$(dirname "$3")/target/crap4java-test.jar"');
    tool(join(dir, 'bin/java'), `echo "$*" >> "$TEST_LOG"
mkdir -p "$TEST_PROJECT/module/target/site/jacoco"
echo '<report/>' > "$TEST_PROJECT/module/target/site/jacoco/jacoco.xml"
exit "\${GATE_EXIT:-0}"`);
    const env = { ...process.env, PATH: `${join(dir, 'bin')}:${process.env.PATH}`, TMPDIR: dir, TEST_LOG: join(dir, 'calls'), TEST_PROJECT: dir };
    const run = (extra = {}) => spawnSync('bash', ['-e', '-c', gate('crap4java')], { cwd: dir, env: { ...env, ...extra }, encoding: 'utf8' });
    const passing = run();
    assert.equal(passing.status, 0, passing.stderr);
    assert.match(readFileSync(join(dir, 'calls'), 'utf8'), /module\/src\/main\/java\/App\.java/);
    mkdirSync(join(dir, 'module2/src/main/java'), { recursive: true });
    writeFileSync(join(dir, 'module2/pom.xml'), '<project/>');
    writeFileSync(join(dir, 'module2/src/main/java/App.java'), 'class App {}');
    const missing = run();
    assert.notEqual(missing.status, 0);
    assert.match(missing.stderr, /Missing JaCoCo coverage for .\/module2/);
    assert.notEqual(run({ GATE_EXIT: '2' }).status, 0);
  });
});
