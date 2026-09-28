import Foundation

/// Tournament field (entry list), including alternates and withdrawal state
/// — useful before a leaderboard exists (e.g. tee-times-only stage).
nonisolated enum FieldQuery {
    static let operation = PGAQuery(operationName: "Field", document: """
    query Field($fieldId: ID!, $includeWithdrawn: Boolean, $changesOnly: Boolean) {
      field(id: $fieldId, includeWithdrawn: $includeWithdrawn, changesOnly: $changesOnly) {
        tournamentName
        id
        lastUpdated
        message
        rangeAvailable
        standingsHeader
        features {
          name
          new
          tooltipText
          tooltipTitle
          fieldStatType
          leaderboardFeatures
        }
        players {
          ...FieldPlayer
          teammate {
            id
            firstName
            lastName
            shortName
            displayName
            amateur
            country
            countryFlag
            qualifier
            alternate
            withdrawn
            status
            owgr
            rankingPoints
          }
        }
        alternates {
          ...FieldPlayer
        }
      }
    }

    fragment FieldPlayer on PlayerField {
      id
      alphaSort
      firstName
      lastName
      shortName
      displayName
      amateur
      favorite
      country
      countryFlag
      headshot
      qualifier
      alternate
      withdrawn
      status
      owgr
      rankingPoints
      rankLogoLight
      rankLogoDark
    }
    """)
}
