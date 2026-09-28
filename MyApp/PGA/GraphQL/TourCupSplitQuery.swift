import Foundation

/// FedExCup standings. `id` is the tour's cup-stat id (PGA TOUR = "02671";
/// see `PGAStatIdentifier.fedExCup`), not a tournament id.
nonisolated enum TourCupSplitQuery {
    static let operation = PGAQuery(operationName: "TourCupSplit", document: """
    query TourCupSplit($tourCode: TourCode!, $id: String, $year: Int, $eventQuery: StatDetailEventQuery) {
      tourCupSplit(tourCode: $tourCode, id: $id, year: $year, eventQuery: $eventQuery) {
        ...TourCupSplitMeta
        fixedHeaders
        columnHeaders
        rankingsHeader
        rankEyebrow
        pointsEyebrow
        message
        partner
        partnerLink
        projectedPlayers {
          ...Player
          ...InfoRow
        }
        officialPlayers {
          ...Player
          ...InfoRow
        }
        yearPills {
          year
          displaySeason
        }
        winner {
          id
          rank
          firstName
          lastName
          displayName
          shortName
          countryFlag
          country
          earnings
          totals {
            label
            value
          }
        }
      }
    }

    fragment TourCupSplitMeta on TourCupSplit {
      id
      title
      detailCopy
      projectedTitle
      projectedLive
      season
      description
      logo
      logoAsset {
        imagePath
        imageOrg
      }
      options
      tournamentPills {
        tournamentId
        displayName
      }
    }

    fragment Player on TourCupCombinedPlayer {
      __typename
      id
      firstName
      lastName
      displayName
      shortName
      countryFlag
      country
      rankingData {
        projected
        official
        event
        movement
        movementAmount
        logo
        logoDark
      }
      pointData {
        projected
        official
        event
        movement
        movementAmount
        logo
        logoDark
      }
      projectedSort
      officialSort
      thisWeekRank
      previousWeekRank
      columnData
      tourBound
    }

    fragment InfoRow on TourCupCombinedInfo {
      logo
      logoDark
      text
      sortValue
      toolTip
    }
    """)
}
