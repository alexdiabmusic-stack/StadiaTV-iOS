Recorded JSON and raw-DEFLATE samples were downloaded from Formula 1’s public timing archive on 2026-09-22. Source session: https://livetiming.formula1.com/static/2025/2025-03-16_Australian_Grand_Prix/2025-03-16_Race/

CarData.z.json and Position.z.json contain the first complete quoted payload from their corresponding .jsonStream files, without the elapsed-time prefix. Tests also construct explicitly synthetic edge-case deltas (22 entries, future channels, status and sparse patches). These are test inputs only; application runtime never selects fixture data automatically.

The `.moving.z.json` samples were extracted from complete lines near the midpoint of the same official archive streams. They contain observed moving-car telemetry/coordinates; channels with sentinel values above 100 are intentionally tested as unavailable.

JolpicaResults.json was captured from https://api.jolpi.ca/ergast/f1/2025/1/results/?format=json&limit=100 on 2026-09-22.
