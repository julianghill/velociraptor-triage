# Velociraptor Collector Builder

This repo ships a helper script that downloads the latest Velociraptor binary, pulls required artifact definitions, and builds collectors for every spec file it finds.

## Quick start
- From the repo root run: `bash createCollectors.sh`
- Collectors are written to `./collectors` by default (set `COLLECTOR_OUTPUT_DIR` to change).
- Specs are read from `./spec` by default. If none are present, the script fetches them from GitHub (`julianghill/velociraptor-triage` on `main` by default).

## Bring your own specs
- Drop your `.yaml`/`.yml` spec files into `./spec`, or point `SPEC_DIR` to a different folder containing your specs.
- To build a single spec only, set `SPEC_FILE=/path/to/your/spec.yaml`.
- To fall back to a different GitHub source when local specs are missing, set `SPEC_SOURCE_REPO="owner/repo"` and optionally `SPEC_SOURCE_REF="branch-or-tag"`.

## Useful environment overrides
- `COLLECTOR_OUTPUT_DIR`: Where collectors are written (default: `$PWD/collectors`).
- `SPEC_DIR`: Directory to scan for specs (default: `./spec`).
- `SPEC_FILE`: Build only this spec file (skips directory scan).
- `SPEC_SOURCE_REPO` / `SPEC_SOURCE_REF`: Remote repo/ref used to fetch specs if none are local (defaults to this repo, `main`).
- `DATA_DIR`, `DATASTORE_DIR`: Override the working folders used for version tracking and artifact downloads.

## Credits
- Inspired by the triage.zip workflow from Digital-Defense-Institute: https://github.com/Digital-Defense-Institute/triage.zip
