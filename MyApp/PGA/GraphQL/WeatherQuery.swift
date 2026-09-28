import Foundation

nonisolated enum WeatherQuery {
    static let operation = PGAQuery(operationName: "Weather", document: """
    query Weather($tournamentId: ID!) {
      weather(tournamentId: $tournamentId) {
        title
        accessibilityText
        hourly {
          title
          condition
          windDirection
          windSpeedKPH
          windSpeedMPH
          humidity
          precipitation
          temperature {
            ... on StandardWeatherTemp {
              __typename
              tempC
              tempF
            }
            ... on RangeWeatherTemp {
              __typename
              minTempC
              minTempF
              maxTempC
              maxTempF
            }
          }
        }
        daily {
          title
          condition
          windDirection
          windSpeedKPH
          windSpeedMPH
          humidity
          precipitation
          temperature {
            ... on StandardWeatherTemp {
              __typename
              tempC
              tempF
            }
            ... on RangeWeatherTemp {
              __typename
              minTempC
              minTempF
              maxTempC
              maxTempF
            }
          }
        }
      }
    }
    """)
}
