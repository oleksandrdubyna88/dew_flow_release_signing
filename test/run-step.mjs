// Usage: node test/run-step.mjs <workflow.yml> <step-id>
// Prints {"shell": ..., "run": ...} for the step. Exit codes:
//   0  printed
//   2  the step id is absent, or ANY run: block in the file contains "${{"
//   2  also when the workflow file cannot be read or parsed
//   64 wrong usage
// The ${{ rule is the workflow's own: no expression inside run:, every value goes through env:.
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';

const [file, id] = process.argv.slice(2);
if (!file || !id || process.argv.length !== 4) {
  console.error('usage: node test/run-step.mjs <workflow.yml> <step-id>');
  process.exit(64);
}

let doc;
try {
  doc = parse(readFileSync(file, 'utf8'));
} catch (err) {
  console.error(`run-step: cannot read ${file}: ${err.message}`);
  process.exit(2);
}

const steps = [];
for (const [jobName, job] of Object.entries(doc?.jobs ?? {})) {
  for (const [index, step] of (job?.steps ?? []).entries()) {
    steps.push({ jobName, index, step });
  }
}

// Every run: block, not only the requested step's.
const offenders = steps.filter(({ step }) => typeof step.run === 'string' && step.run.includes('${{'));
if (offenders.length > 0) {
  for (const { jobName, index, step } of offenders) {
    console.error(`run-step: step '${step.id ?? step.name ?? index}' of job '${jobName}' has "\${{" inside run:`);
  }
  process.exit(2);
}

const hit = steps.find(({ step }) => step.id === id);
if (!hit || typeof hit.step.run !== 'string') {
  console.error(`run-step: no step with id '${id}' and a run: text in ${file}`);
  process.exit(2);
}

// shell: the step's own; the runner's default for a run: step on Windows would be pwsh, but every step here names its shell.
const shell = hit.step.shell ?? 'pwsh';
process.stdout.write(JSON.stringify({ shell, run: hit.step.run }) + '\n');
