# Velociraptor Collector Builder

This repo ships a helper script that downloads the latest Velociraptor binary, pulls required artifact definitions, and builds collectors for every spec file it finds.

## Quick start
- Download the script locally: `git clone https://github.com/julianghill/velociraptor-triage.git`
- From the repo root run: `bash createCollectors.sh` (collectors land in `./collectors`, data in `./data`, datastore in `./datastore`; the script moves built collectors out of the datastore for you).
- Specs are read from `./spec` by default. If none are present, the script fetches them from GitHub (`julianghill/velociraptor-triage` on `main` by default).

## Examples
- Build all specs with SFTP overrides and place collectors in a custom folder:
  ```bash
  bash createCollectors.sh \
    --sftp-host sftp.example.com:22 \
    --sftp-user myuser \
    --sftp-key-path /path/to/id_ed25519 \
    --sftp-remote-dir /remote/upload/path \
    --output-dir /mnt/storage/collectors
  ```
- Render specs only (no collectors), writing the rendered files to a folder:
  ```bash
  bash createCollectors.sh \
    --spec-only \
    --sftp-host sftp.example.com:22 \
    --sftp-user myuser \
    --sftp-key-path /path/to/id_ed25519 \
    --sftp-remote-dir /remote/upload/path \
    --spec-output ./rendered_specs_out
  ```
- Build a single spec and leave others untouched:
  ```bash
  SPEC_FILE=spec/winpmemRemoteSpec.yaml bash createCollectors.sh
  ```

## New CLI flags for automation
- `--spec-only`: Render specs (fetching them if missing) with overrides and exit—no collector build. Leaves rendered specs in `./rendered_specs` by default; use `--spec-output` to copy them elsewhere.
- `--sftp-host <host[:port]>`, `--sftp-user <user>`, `--sftp-key-path <path>`, `--sftp-remote-dir <dir>`: Inject SFTP settings into SFTP-based specs. If any are provided, all four are required.
- `--workdir <path>`: Working directory (default: repo directory). Targets, datastore, rendered specs, and binary live here.
- `--output-dir <path>`: Where collectors are written (default: `<workdir>/collectors`).
- `--spec-output <path>`: Where to write rendered specs in `--spec-only` mode. If multiple specs are rendered, provide a directory path.

## Bring your own specs
- Drop your `.yaml`/`.yml` spec files into `./spec`, or point `SPEC_DIR` to a different folder containing your specs.
- To build a single spec only, set `SPEC_FILE=/path/to/your/spec.yaml`.
- To fall back to a different GitHub source when local specs are missing, set `SPEC_SOURCE_REPO="owner/repo"` and optionally `SPEC_SOURCE_REF="branch-or-tag"`.

## Useful environment overrides
- `COLLECTOR_OUTPUT_DIR`: Where collectors are written (default: `<workdir>/collectors`).
- `SPEC_DIR`: Directory to scan for specs (default: `./spec`).
- `SPEC_FILE`: Build only this spec file (skips directory scan).
- `SPEC_SOURCE_REPO` / `SPEC_SOURCE_REF`: Remote repo/ref used to fetch specs if none are local (defaults to this repo, `main`).
- `DATA_DIR`, `DATASTORE_DIR`: Override the working folders used for version tracking and artifact downloads.

## Credits
- Inspired by the triage.zip workflow from Digital-Defense-Institute: https://github.com/Digital-Defense-Institute/triage.zip

## To do
- Add Ansible usage guidance for deploying a Velociraptor server and driving this collector builder from playbooks.
