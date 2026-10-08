# Documentation

| Where | What |
|---|---|
| `integrations/` | One note per sports provider: the endpoints that were verified, licensing, and the gaps that are disclosed. Code comments refer to these by file name, for example `EPL-INTEGRATION.md`. |
| `benchmarks/` | Measurements of the guide and the stream linker on real exports. |
| `archive/` | Reviews of earlier states of the code. Kept for history; not kept up to date. |
| `../MatchLinker/` | The stream linker's harness, prompts and Python reference. `StreamLinker.swift` and its tests are symlinks to the copies the app builds. |

`Public-ESPN-API-main/` and `odds-api-main/` at the repository root are snapshots of third-party API documentation. Nothing builds them and nothing in the app reads them.

## Running the tests

`scripts/test-all.sh` runs every suite and reports all failures: the static checks, each `*CoreTests` package, `MatchLinker`, and the Xcode unit tests. It needs macOS with Xcode. `scripts/test-all.sh checks` runs only the checks and works anywhere.

## Release checks

`scripts/check-release-config.sh` reports release-readiness problems in the build configuration (premium unlock, missing keys). `scripts/check-dynamic-type.sh` stops the count of fixed-size fonts growing. Xcode Cloud runs both from `ci_scripts/ci_pre_xcodebuild.sh`, as warnings unless `STRICT_RELEASE_CONFIG=1` or `STRICT_DYNAMIC_TYPE=1` is set.
