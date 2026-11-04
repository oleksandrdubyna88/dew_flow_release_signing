// Usage: node test/wiring.mjs <sign-windows.yml> <ci.yml>
// Pins how the allow-unsigned-release input reaches the mode step. The self-test harness builds the step's
// environment itself, and the two real calls of ci.yml cannot tell the input from a wrong source (trial-call-forced is
// permitted either way, trial-call is not forced), so the SOURCE of the mapping is checked here, on the parsed YAML.
// It also checks that the all-green gate of ci.yml needs exactly every other job: a job missing from its needs: list
// would not be gated.
// Exit codes:
//   0  the wiring is as pinned (prints "wiring ok: ...")
//   1  a pinned fact does not hold (each one is printed)
//   2  the workflow file cannot be read or parsed
//   64 wrong usage
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';

const [file, ciFile] = process.argv.slice(2);
if (!file || !ciFile || process.argv.length !== 4) {
  console.error('usage: node test/wiring.mjs <sign-windows.yml> <ci.yml>');
  process.exit(64);
}

let text;
let doc;
let ciDoc;
try {
  text = readFileSync(file, 'utf8');
  doc = parse(text);
} catch (err) {
  console.error(`wiring: cannot read ${file}: ${err.message}`);
  process.exit(2);
}
try {
  ciDoc = parse(readFileSync(ciFile, 'utf8'));
} catch (err) {
  console.error(`wiring: cannot read ${ciFile}: ${err.message}`);
  process.exit(2);
}

const problems = [];

// 1. The input: a boolean, default false.
const input = doc?.on?.workflow_call?.inputs?.['allow-unsigned-release'];
if (!input) {
  problems.push("input 'allow-unsigned-release' is missing from on.workflow_call.inputs");
} else {
  if (input.type !== 'boolean') problems.push(`input 'allow-unsigned-release' has type ${JSON.stringify(input.type)}, expected "boolean"`);
  if (input.default !== false) problems.push(`input 'allow-unsigned-release' has default ${JSON.stringify(input.default)}, expected false`);
}

// 2. The mode step's env: both booleans come from their own input.
const modeSteps = [];
for (const [jobName, job] of Object.entries(doc?.jobs ?? {})) {
  for (const step of job?.steps ?? []) {
    if (step?.id === 'mode') modeSteps.push({ jobName, step });
  }
}
if (modeSteps.length !== 1) {
  problems.push(`expected exactly one step with id 'mode', found ${modeSteps.length}`);
} else {
  const env = modeSteps[0].step.env ?? {};
  const wanted = {
    ALLOW_UNSIGNED_RELEASE: '${{ inputs.allow-unsigned-release }}',
    REQUIRED: '${{ inputs.required }}',
  };
  for (const [name, expr] of Object.entries(wanted)) {
    if (env[name] !== expr) problems.push(`mode step env ${name} is ${JSON.stringify(env[name])}, expected ${JSON.stringify(expr)}`);
  }
}

// 3. No other expression in the file reads the input (any spelling GitHub accepts: it is case-insensitive).
const expressions = [...text.matchAll(/\$\{\{([\s\S]*?)\}\}/g)].map((m) => m[1]);
const readers = expressions.filter((e) => /allow-unsigned-release/i.test(e));
if (readers.length !== 1) {
  problems.push(`${readers.length} expressions name allow-unsigned-release, expected exactly one (the mode step's env)`);
}

// 4. The gate: ci.yml's all-green job needs exactly every other job (order does not matter).
const ciJobs = Object.keys(ciDoc?.jobs ?? {});
const gate = ciDoc?.jobs?.['all-green'];
if (!gate) {
  problems.push(`${ciFile} has no job 'all-green'`);
} else {
  const rawNeeds = gate.needs ?? [];
  const needs = Array.isArray(rawNeeds) ? rawNeeds : [rawNeeds];
  const others = ciJobs.filter((j) => j !== 'all-green');
  const missing = others.filter((j) => !needs.includes(j));
  const extra = needs.filter((j) => !others.includes(j));
  if (missing.length > 0) problems.push(`all-green does not need: ${missing.join(', ')} (a job outside the gate)`);
  if (extra.length > 0) problems.push(`all-green needs jobs that do not exist or are itself: ${extra.join(', ')}`);
  if (new Set(needs).size !== needs.length) problems.push('all-green needs lists a job twice');
}

if (problems.length > 0) {
  for (const p of problems) console.error(`wiring: ${p}`);
  process.exit(1);
}
console.log('wiring ok: mode reads allow-unsigned-release from the input only; all-green needs every other job');
