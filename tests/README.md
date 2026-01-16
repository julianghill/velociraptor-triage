# Test Scripts

These scripts live here so you can quickly validate changes to `createCollectors.sh`.

## Smoke test
```bash
bash tests/run_smoke.sh
```

This runs `--spec-only` and confirms rendered specs are produced without needing a Velociraptor binary.

## Agent build test
```bash
bash tests/run_agents.sh
```

By default it expects `./velociraptor` and `./server.config.yaml`. Override with `VELO_BINARY` and `SERVER_CONFIG` as needed.

## Collector build test
```bash
bash tests/run_collectors.sh
```

This runs a collector build and checks that at least one collector was produced. Use `SPEC_FILE=spec/yourSpec.yaml` to target a single spec.
