# NBA fixture provenance

Every file in this directory is **hand-constructed**, not captured from a live
NBA response — both `cdn.nba.com` and `stats.nba.com` were unreachable from
the network this integration was built on (see `NBA-INTEGRATION.md`). These
fixtures prove the mappers and reducer obey their own contracts; they do
**not** prove the wire format matches NBA's actual responses. Wire-format
fidelity is unverified pending a live check from a network that can reach
both hosts.

Field vocabulary for each fixture was derived from the existing production
mapper/DTO code, not guessed independently:

| File | origin | Shape derived from |
| --- | --- | --- |
| `scoreboard.constructed.json` | constructed 2026-09-22 | `NBAScoreboardDTO.swift`, `NBAGameMapper.game(_:)`/`.team(_:)` |
| `scoreboard-empty-offseason.constructed.json` | constructed 2026-09-22 | Same envelope, zero games — a legitimate NBA offseason result |
| `boxscore-live.constructed.json` | constructed 2026-09-22 | `NBABoxScoreDTO.swift`, `NBABoxScoreMapper.players(_:)`/`.teamStats(_:)`/`.onCourt(_:)` |
| `boxscore-final-ot.constructed.json` | constructed 2026-09-22 | Same shape, `gameStatus: 3`, `period: 5` (one overtime) |
| `playbyplay-live.constructed.json` | constructed 2026-09-22 | `NBAPlayByPlayDTO.swift`, `NBAPlayMapper.build(_:)` field list |
| `playbyplay-v3.constructed.json` | constructed 2026-09-22 | `NBAStatsTableDTO.swift` columnar shape, `NBAPlayByPlayV3Response` |
| `schedule-cdn.constructed.json` | constructed 2026-09-22 | `NBAScheduleDTO.swift` (`leagueSchedule.gameDates[].games`) |
| `standings-v3.constructed.json` | constructed 2026-09-22 | `NBAStatsTableDTO.swift` columnar shape, public `leaguestandingsv3` header names as referenced in `NBAProvider.standingRow(_:)`'s doc comment |
| `roster.constructed.json` | constructed 2026-09-22 | `NBAStatsTableDTO.swift` columnar shape, public `commonteamroster` header names as referenced in `NBAProvider.roster(teamID:)`'s doc comment |

No fixture is loaded by the app itself. Tests require no NBA server.
