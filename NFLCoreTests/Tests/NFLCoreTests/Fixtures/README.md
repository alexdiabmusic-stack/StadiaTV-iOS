# NFL fixture provenance

`regular-final.json`, summaries, teams, rosters, standings, injuries, and weeks are public NFL Shield responses captured September 22, 2026 using the SportsDataverse public WEB_DESKTOP flow. The completed game fixture is Dallas at Philadelphia, September 4, 2025. Identity headers and token responses are never persisted.

`status-cases.json` contains explicitly constructed boundary cases applied to the recorded game, not recorded live-state claims. All unit tests are offline. `--live-smoke` is a separate opt-in integration diagnostic.

The passing/rushing/receiving/punting regression values are cross-checked against the gamebook URL supplied by summary.gameBookUrl. Numeric GSIS stat IDs are isolated in NFLStatisticsMapper and unknown IDs remain preserved in play participants.
