package com.nuvio.app.features.sports.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.EmojiEvents
import androidx.compose.material.icons.rounded.GpsFixed
import androidx.compose.material.icons.rounded.Lens
import androidx.compose.material.icons.rounded.SportsBaseball
import androidx.compose.material.icons.rounded.SportsBasketball
import androidx.compose.material.icons.rounded.SportsCricket
import androidx.compose.material.icons.rounded.SportsFootball
import androidx.compose.material.icons.rounded.SportsGolf
import androidx.compose.material.icons.rounded.SportsHandball
import androidx.compose.material.icons.rounded.SportsHockey
import androidx.compose.material.icons.rounded.SportsKabaddi
import androidx.compose.material.icons.rounded.SportsMma
import androidx.compose.material.icons.rounded.SportsMotorsports
import androidx.compose.material.icons.rounded.SportsRugby
import androidx.compose.material.icons.rounded.SportsSoccer
import androidx.compose.material.icons.rounded.SportsTennis
import androidx.compose.material.icons.rounded.SportsVolleyball
import androidx.compose.ui.graphics.vector.ImageVector
import com.nuvio.app.features.sports.Sport

/**
 * A sport's symbol as a single-colour vector icon, in place of the colour emoji the sports data
 * carries ([Sport.icon]), so the Sports screens look like the rest of the app.
 */
internal val Sport.vector: ImageVector
    get() = when (this) {
        Sport.AMERICAN_FOOTBALL -> Icons.Rounded.SportsFootball
        Sport.BASKETBALL -> Icons.Rounded.SportsBasketball
        Sport.HOCKEY, Sport.LACROSSE -> Icons.Rounded.SportsHockey
        Sport.BASEBALL -> Icons.Rounded.SportsBaseball
        Sport.FOOTBALL -> Icons.Rounded.SportsSoccer
        Sport.RUGBY, Sport.AUSSIE_RULES, Sport.GAELIC -> Icons.Rounded.SportsRugby
        Sport.FIGHTING -> Icons.Rounded.SportsMma
        Sport.RACING -> Icons.Rounded.SportsMotorsports
        Sport.GOLF -> Icons.Rounded.SportsGolf
        Sport.TENNIS -> Icons.Rounded.SportsTennis
        Sport.CRICKET -> Icons.Rounded.SportsCricket
        Sport.DARTS -> Icons.Rounded.GpsFixed
        Sport.SNOOKER -> Icons.Rounded.Lens
        Sport.WRESTLING -> Icons.Rounded.SportsKabaddi
        Sport.VOLLEYBALL -> Icons.Rounded.SportsVolleyball
        Sport.NETBALL -> Icons.Rounded.SportsHandball
        Sport.OTHER -> Icons.Rounded.EmojiEvents
    }
