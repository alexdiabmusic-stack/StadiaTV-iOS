# NHL fixtures

Downloaded directly from api-web.nhle.com on 2026-09-21.

- final-* : game 2023020204, complete landing, boxscore and play-by-play responses.
- overtime: game 2023020582, complete play-by-play.
- shootout: game 2023020592, complete play-by-play.
- pregame: game 2026010049, complete play-by-play before puck drop.
- score: score/2024-01-01.
- live-regulation and intermission: deterministic variations of final-play-by-play, with gameState, period, clock and play cutoff changed. These are schema fixtures, not claimed live recordings.

Tests do not contact NHL servers. Production files are symlinked into the package target to prevent a separate test-only implementation.
