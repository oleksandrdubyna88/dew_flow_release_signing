# dew_flow_release_signing

Shared GitHub Actions workflows for the dew_flow repositories: Windows Authenticode signing with Azure Artifact Signing.

## What `sign-windows.yml` does

A reusable workflow (`on: workflow_call`). The caller builds its Windows packages and uploads each one as an
artifact `unsigned-NAME`. For every NAME in `artifacts` (one matrix leg each, on `windows-2025`) the workflow:

1. checks the three JSON inputs (`inputs` step);
2. downloads `unsigned-NAME` into `in/` and checks that `in/` holds exactly one directory, the package folder (`pkg` step);
3. decides `sign`, `skip` or red from the six signing variables of the caller's environment (`mode` step);
4. lists the binaries: the caller's own files must arrive unsigned, other unsigned files must be declared in
   `extra-files`, vendor-signed files must still be `Valid` (`inventory` step, before any login, in every mode);
5. in `sign` mode: logs in to Azure with OIDC and signs the listed files with `azure/artifact-signing-action`;
6. verifies the signatures: `Valid`, timestamped, signer equal to `SIGNING_PUBLISHER`, kept vendor files still `Valid`
   (`verify` step; in `skip` mode it only says the files are unsigned);
7. packs `out/PKG.zip` and `out/PKG.zip.sha256` (`pack` step), extracts the zip and compares every path and SHA-256
   with `in/PKG` (`check` step);
8. uploads `out/` as the artifact `NAME` (`retention-days: 7`).

The workflow builds nothing, publishes nothing and reads no secret. The caller owns build, smoke tests and release.

## Inputs

- `artifacts` (string, required)
  JSON list of output artifact names, e.g. ["cli-win-x64","cli-win-arm64"]. For each NAME the caller uploaded unsigned-NAME holding exactly one top-level directory. Non-empty; each name matches ^[A-Za-z0-9._-]+$.
- `own-files` (string, required)
  JSON list of package-relative paths of the caller's OWN binaries, e.g. ["creds.exe"]. Non-empty; "/" separators; no globs; no "." or ".." segments. Each must exist once and arrive unsigned.
- `extra-files` (string, optional, default `'[]'`)
  JSON list of file-NAME globs (PowerShell -like: * ? []) of other files that may be signed when they arrive unsigned, e.g. ["e_sqlite3.dll","*tree-sitter*.dll"]. No path separators. An unsigned PE that is neither an own file nor matched here is red.
- `required` (boolean, required)
  true: missing configuration or any failure is red. Independently, a caller ref under refs/tags/ is treated as required.
- `environment` (string, optional, default `release-signing`)
  The caller's environment that holds AZURE_CLIENT_ID, AZURE_TENANT_ID, SIGNING_ENDPOINT, SIGNING_ACCOUNT, SIGNING_PROFILE, SIGNING_PUBLISHER and the OIDC trust.

The six variables of the caller's `environment` (none is a secret): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`SIGNING_ENDPOINT`, `SIGNING_ACCOUNT`, `SIGNING_PROFILE`, `SIGNING_PUBLISHER`.

| Variables set | Forced (`required: true`, or the caller ref is under `refs/tags/`) | Result |
|---|---|---|
| all six | any | sign |
| none | no | skip: an UNSIGNED trial, with a warning |
| none | yes | red, naming the six variables |
| one to five | any | red: a half configuration is never a skip |

A job that names an environment the caller's repository does not have makes GitHub create it, empty. A typo in
`environment` is therefore not an error: a trial takes `skip`, a tag is red. Every message names the environment.

## The artifact contract

- In: for each NAME in `artifacts`, an artifact `unsigned-NAME` holding exactly one top-level directory PKG
  (for example `creds-0.4.6-win-x64`). Upload the PARENT of PKG, so the directory is kept in the artifact.
- Out: an artifact `NAME` holding exactly `PKG.zip` and `PKG.zip.sha256`.
  - The zip has one top-level entry, `PKG/`, made with `(cd in && 7z a "../out/PKG.zip" "PKG")`.
  - The checksum is `sha256sum PKG.zip`, made inside `out/`, so `sha256sum -c` passes there.
- Outputs of the steps, for the steps that follow (`id`: output): `pkg`: `name`, `dir`; `mode`: `mode`;
  `inventory`: `files`, `count`, `kept-files`, `kept-count`.

## Security rules

- Only declared files are signed: own files (exact package-relative paths) and unsigned files that match
  `extra-files`. An unsigned PE that nobody declared is red.
- An own file must arrive unsigned. A vendor-signed file named as the product's binary is red.
- A tag ref always requires signing, whatever `required` says.
- There is no secret. Values come from `vars`, and no `${{ }}` expression is written inside any `run:`: every value
  reaches a script through `env:`. The self-test refuses a workflow that breaks this rule.
- The top level is `permissions: {}`. The job has `contents: read` and `id-token: write` only. A caller job must grant
  the same two to call the workflow.
- `azure/artifact-signing-action` runs with `cache-dependencies: false` and `exclude-environment-credential: true`,
  so only the `azure/login` session can authenticate.
- Every action is pinned by its 40-hex commit SHA. The workflow checks out nothing.
- `verify` compares the signer simple name with `SIGNING_PUBLISHER` exactly (ordinal, case-sensitive).

## Caller snippet

```yaml
cli-sign:
  name: sign creds cli (windows)
  needs: cli-binaries
  permissions:
    contents: read
    id-token: write
  uses: oleksandrdubyna88/dew_flow_release_signing/.github/workflows/sign-windows.yml@<40-hex> # v1.0.0
  with:
    artifacts: '["cli-win-x64","cli-win-arm64"]'
    own-files: '["creds.exe"]'
    required: ${{ startsWith(github.ref, 'refs/tags/') }}
```

Pin the 40-hex SHA of a release tag, never a branch.

## Owner setup, once

Summary of O1 to O9. The full text is in `dew_flow_creds_for_devs · todo/PLAN_windows_code_signing.md` section 4.

- O1: an Azure subscription in the owner's Entra tenant.
- O2: register the `Microsoft.CodeSigning` provider on it.
- O3: create an Artifact Signing account (Basic SKU) and record its endpoint and name.
- O4: identity validation, Public Trust, Organization. It needs legal documents and can take days.
- O5: a Public Trust certificate profile; record its name and the organization name of the certificate subject
  (`SIGNING_PUBLISHER`).
- O6: a user-assigned managed identity with the role *Artifact Signing Certificate Profile Signer* on the profile, and
  one federated credential per caller repository for its environment `release-signing`.
- O7: in each caller repository, an environment `release-signing` limited to the release branches and tags, holding the
  six variables. Until the merge the rule also admits the PR branch.
- O8: re-read the tag ruleset, the guard that makes a tag a human decision.
- O9: after the merge, remove the PR branches from the deployment rules.

## Self-test

CI (`.github/workflows/ci.yml`) runs on every branch push and pull request:

- `lint`: actionlint (pinned by version and SHA-256) with shellcheck over the `run:` blocks;
- `harness`: `test/selftest.ps1` runs single steps of `sign-windows.yml` the way the GitHub runner runs them, one case
  at a time, and prints `case ID: pass` or `case ID: FAIL`;
- `trial-input`, `trial-call`, `trial-check`: one real call in the unsigned trial road (environment
  `selftest-no-signing`, which never holds variables) and the checks of its result.

To run the harness on a Windows machine with PowerShell 7, Git for Windows, 7-Zip and the .NET SDK:

```powershell
npm ci --ignore-scripts
pwsh -File test/selftest.ps1
```

The fixtures are made at run time in a folder whose path has a space, and removed at the end. Nothing binary is
committed. The `sign` road needs Azure and is proven by the first real release of a caller.

## License

MIT, see `LICENSE`.
