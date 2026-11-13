package com.teale.android.service

/** Real supply state, published by [SupplyService.state] for the UI and notification. */
sealed interface SupplyState {
    /** Supply disabled or the service is not running. */
    data object Off : SupplyState

    data object Starting : SupplyState

    /** A supply process exited unexpectedly; the next attempt starts after a backoff. */
    data class Restarting(
        val attempt: Int,
        val maxAttempts: Int,
        val reason: String,
    ) : SupplyState

    data object WaitingForCharge : SupplyState

    data class ThermalPaused(val level: String) : SupplyState

    data class MissingArtifacts(val detail: String) : SupplyState

    data class Error(val detail: String) : SupplyState

    data class Running(
        val profile: SupplyRuntimeProfile,
        val fellBackToCpu: Boolean,
        /** The user paused serving from the app; processes stay up. */
        val userPaused: Boolean = false,
        /** Last `/status` answer from teale-node, null until the first poll succeeds. */
        val node: NodeStatus? = null,
    ) : SupplyState
}
