package com.nuvio.app

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.dp
import com.nuvio.app.core.ui.CameraBand
import com.nuvio.app.core.ui.Fold

class Hinge {
    internal var fold by mutableStateOf<Fold?>(null)
        private set

    internal var cameraBand by mutableStateOf<CameraBand?>(null)
        private set

    fun update(top: Double, bottom: Double) {
        fold = Fold(top = top.dp, bottom = bottom.dp)
    }

    fun clear() {
        fold = null
    }

    fun updateCameraBand(top: Double, bottom: Double, cameraStart: Double, cameraEnd: Double) {
        val band = CameraBand(top = top.dp, bottom = bottom.dp, cameraStart = cameraStart.dp, cameraEnd = cameraEnd.dp)
        if (band != cameraBand) cameraBand = band
    }

    fun clearCameraBand() {
        if (cameraBand != null) cameraBand = null
    }
}
