package com.photosbackup.domain

import java.util.Locale

/** One bridge request's upload, as the parallelism controller reads it (the Mac's UploadSample). */
data class UploadSample(
    /** Bytes of the items Google stored; items it already had send nothing. */
    val bytes: Long,
    /** From sending the request to its last item's answer. */
    val seconds: Double,
    /** Items that went up (not already in Google Photos). */
    val items: Int,
    /** Google answered HTTP 429 during the request. */
    val rateLimited: Boolean = false,
    /** Items that failed in a way sending again may fix: a 5xx, a 408, a dropped connection. */
    val serverFailures: Int = 0,
    /** The run's first request, whose time includes gpmc's import and the sign-in. */
    val includesStartUp: Boolean = false,
)

/**
 * How many uploads go at once, decided between bridge requests (issue #59, a port of the Mac's
 * UploadParallelism from issue #50).
 *
 * Automatic starts at four and adds one while each step is measurably faster (10% more bytes a
 * second). Unlike the Mac's 0.6.0 controller, one step that is not faster does not end the climb:
 * phone uplinks are noisy (radio, Wi-Fi roaming, thermal throttling), so a level is measured
 * again, and only a second miss returns to the best level and stays there. Google pushing back
 * ends the climb for the run: a 429 halves the level, two or more retryable failures in one
 * request take one off. Manual is exactly the chosen number. Both stay within the network's cap:
 * [UNMETERED_CAP] on Wi-Fi and other unmetered networks, [METERED_CAP] on a metered one, lower
 * than the desktop's 16 for battery and heat.
 */
@ConsistentCopyVisibility
data class UploadParallelism
private constructor(
    val cap: Int,
    val current: Int,
    val isClimbing: Boolean,
    val isAutomatic: Boolean,
    private val reason: Reason,
    /** Manual: the number chosen in Settings, which a recap restores. */
    private val chosen: Int = 0,
    /** The level found no faster, for [summary]. */
    private val tried: Int = 0,
    private val bestLevel: Int = 0,
    private val bestRate: Double = 0.0,
    private val misses: Int = 0,
    private val pendingBytes: Long = 0,
    private val pendingSeconds: Double = 0.0,
) {
    private enum class Reason { FINDING, NO_FASTER, MOST, RATE_LIMITED, SERVER_TROUBLE, CHOSEN }

    fun measured(sample: UploadSample): UploadParallelism {
        if (!isAutomatic) return this
        if (sample.rateLimited) return backOff(current / 2, Reason.RATE_LIMITED)
        if (sample.serverFailures >= SERVER_FAILURES_THAT_COUNT)
            return backOff(current - 1, Reason.SERVER_TROUBLE)
        if (!isClimbing || sample.items <= 0 || sample.includesStartUp) return this
        val bytes = pendingBytes + sample.bytes
        val seconds = pendingSeconds + sample.seconds
        if (bytes < DECISION_BYTES || seconds < DECISION_SECONDS)
            return copy(pendingBytes = bytes, pendingSeconds = seconds)
        val rate = bytes / seconds
        val judged = copy(pendingBytes = 0, pendingSeconds = 0.0)
        if (bestLevel > 0 && rate < bestRate * (1 + IMPROVEMENT)) {
            if (misses + 1 < MISSES_TO_SETTLE) return judged.copy(misses = misses + 1)
            return judged.copy(
                current = bestLevel,
                isClimbing = false,
                reason = Reason.NO_FASTER,
                tried = current,
                misses = 0,
            )
        }
        val best = judged.copy(bestLevel = current, bestRate = rate, misses = 0)
        return if (current < cap) best.copy(current = current + 1)
        else best.copy(isClimbing = false, reason = Reason.MOST)
    }

    /** The network changed mid-run (Wi-Fi to mobile data or back): the cap follows it. */
    fun recapped(networkCap: Int): UploadParallelism {
        val limit = networkCap.coerceIn(1, UNMETERED_CAP)
        if (limit == cap) return this
        if (!isAutomatic) return copy(cap = limit, current = minOf(chosen, limit))
        // Google's pushback holds for the run whatever the network.
        if (reason == Reason.RATE_LIMITED || reason == Reason.SERVER_TROUBLE)
            return copy(cap = limit, current = minOf(current, limit))
        return automatic(limit)
    }

    private fun backOff(level: Int, cause: Reason) =
        copy(
            current = maxOf(1, level),
            isClimbing = false,
            reason = cause,
            misses = 0,
            pendingBytes = 0,
            pendingSeconds = 0.0,
        )

    /** Where it is and why, in the Mac's Diagnostics wording; the notice during a 429 hold shows it. */
    val summary: String
        get() {
            val level = "$current at a time"
            return when (reason) {
                Reason.FINDING -> "$level, finding the fastest"
                Reason.NO_FASTER -> "$level (no faster at $tried)"
                Reason.MOST -> "$level (the most it uses on this network)"
                Reason.RATE_LIMITED -> "$level (Google asked to slow down)"
                Reason.SERVER_TROUBLE -> "$level (Google had trouble keeping up)"
                Reason.CHOSEN -> "$level (chosen in Settings)"
            }
        }

    companion object {
        const val UNMETERED_CAP = 8
        const val METERED_CAP = 2
        const val INITIAL = 4
        const val IMPROVEMENT = 0.10
        /** A level is judged on at least this much, as on the Mac. */
        const val DECISION_BYTES = 24_000_000L
        const val DECISION_SECONDS = 4.0
        /** One passing 5xx is Google's noise, not pressure. */
        const val SERVER_FAILURES_THAT_COUNT = 2
        /** A level must miss twice before the climb ends; one miss may be the radio's noise. */
        const val MISSES_TO_SETTLE = 2
        /** The Settings value that means Automatic; 1..[UNMETERED_CAP] are Manual. */
        const val AUTOMATIC = 0

        fun networkCap(metered: Boolean) = if (metered) METERED_CAP else UNMETERED_CAP

        fun automatic(networkCap: Int): UploadParallelism {
            val cap = networkCap.coerceIn(1, UNMETERED_CAP)
            val start = minOf(INITIAL, cap)
            return UploadParallelism(
                cap = cap,
                current = start,
                isClimbing = start < cap,
                isAutomatic = true,
                reason = if (start < cap) Reason.FINDING else Reason.MOST,
            )
        }

        fun manual(chosen: Int, networkCap: Int): UploadParallelism {
            val cap = networkCap.coerceIn(1, UNMETERED_CAP)
            val wanted = chosen.coerceIn(1, UNMETERED_CAP)
            return UploadParallelism(
                cap = cap,
                current = minOf(wanted, cap),
                isClimbing = false,
                isAutomatic = false,
                reason = Reason.CHOSEN,
                chosen = wanted,
            )
        }

        /** [setting] is the stored choice: [AUTOMATIC], or a number of uploads at once. */
        fun forSetting(setting: Int, metered: Boolean): UploadParallelism =
            if (setting == AUTOMATIC) automatic(networkCap(metered))
            else manual(setting, networkCap(metered))
    }
}

/**
 * What a failed item tells the parallelism controller, read from the bridge's item_failed text as
 * the Mac's FailureClassifier reads it: gpmc 0.9.0 keeps only an exception's text, so requests'
 * "503 Server Error: ..." or urllib3's "too many 503 error responses" is all either side has.
 */
object UploadFailure {
    enum class Kind { RATE_LIMITED, RETRYABLE, PERMANENT }

    private val statusPatterns =
        listOf(
                """\b([1-5][0-9]{2}) (?:Client|Server) Error\b""",
                """too many ([1-5][0-9]{2}) error responses""",
                """\bHTTP(?: Error)?:? ([1-5][0-9]{2})\b""",
                """\bstatus(?: code)?:? ([1-5][0-9]{2})\b""",
            )
            .map { Regex(it, RegexOption.IGNORE_CASE) }

    private val networkMarkers =
        listOf(
            "timed out", "timeout", "connection reset", "connection aborted", "connection refused",
            "connectionerror", "remotedisconnected", "max retries exceeded", "newconnectionerror",
            "nameresolutionerror", "name resolution", "network is unreachable", "no route to host",
            "broken pipe", "temporarily unavailable", "eof occurred",
        )

    fun classify(message: String, bridgeRetryable: Boolean?): Kind {
        val status = statusPatterns.firstNotNullOfOrNull { it.find(message)?.groupValues?.get(1)?.toInt() }
        if (status != null) {
            if (status == 429) return Kind.RATE_LIMITED
            if (status == 408 || status >= 500) return Kind.RETRYABLE
            if (status >= 400) return Kind.PERMANENT
        }
        val lowered = message.lowercase(Locale.ROOT)
        if ("too many requests" in lowered) return Kind.RATE_LIMITED
        if (networkMarkers.any { it in lowered }) return Kind.RETRYABLE
        return if (bridgeRetryable == true) Kind.RETRYABLE else Kind.PERMANENT
    }
}

/**
 * How much is staged ahead of the upload: while one batch uploads, the next is copied out of the
 * content provider and hashed, so the network does not wait on storage. A staged item is a full
 * copy in the app's cache, so the batch uploading and the one ahead together stay within
 * [BYTES_AHEAD], and staging leaves [FREE_SPACE_FLOOR] of the cache volume free. Both are margins
 * chosen for phones, not measured limits.
 */
object StagingWindow {
    const val BATCH_ITEMS = 32
    const val BATCH_BYTES = 400_000_000L
    const val BYTES_AHEAD = 1_000_000_000L
    const val FREE_SPACE_FLOOR = 1_000_000_000L

    /**
     * Whether the next item may be staged now.
     * @param staged bytes on disk not yet uploaded and deleted, the batch uploading included.
     * @param next the item's size, or null when the provider does not say; the window may then
     *   pass the cap by that one item.
     * @param freeSpace what the cache volume has available, or null if it did not say.
     */
    fun mayStage(staged: Long, next: Long?, freeSpace: Long?): Boolean {
        val fits = if (next != null) staged + next <= BYTES_AHEAD else staged < BYTES_AHEAD
        if (!fits) return false
        if (freeSpace == null) return true
        return freeSpace - (next ?: 0L) >= FREE_SPACE_FLOOR
    }

    /** A batch closes at [BATCH_ITEMS] items or [BATCH_BYTES] bytes, whichever comes first. */
    fun full(items: Int, bytes: Long): Boolean = items >= BATCH_ITEMS || bytes >= BATCH_BYTES

    /** The largest first, so a long video starts early instead of being the batch's tail. */
    fun <T> largestFirst(items: List<T>, size: (T) -> Long): List<T> =
        items.withIndex()
            .sortedWith(compareByDescending<IndexedValue<T>> { size(it.value) }.thenBy { it.index })
            .map { it.value }
}

/**
 * Upload speed from the bridge's per-file progress (bytes actually sent), for the notification.
 * Speed is what was sent over the last [WINDOW_MILLIS]; nothing is shown before [MINIMUM_SPAN_MILLIS]
 * of sending. Progress arrives from the bridge's upload threads at once, hence the locks.
 */
class ThroughputMeter {
    private val perItem = HashMap<String, Long>()
    private val marks = ArrayDeque<Pair<Long, Long>>() // (at, running total)
    var bytesSent = 0L
        private set

    @Synchronized
    fun sent(id: String, total: Long, at: Long) {
        val before = perItem[id] ?: 0L
        // Less than before: the item started over (a new attempt).
        val added = if (total >= before) total - before else total
        perItem[id] = total
        if (added <= 0) return
        bytesSent += added
        marks.addLast(at to bytesSent)
        // Keep one mark at or before the window's start as the baseline.
        while (marks.size > 2 && marks[1].first <= at - WINDOW_MILLIS) marks.removeFirst()
    }

    /** Item [id] has an outcome; if it is sent again it starts from nothing. */
    @Synchronized
    fun finished(id: String) {
        perItem.remove(id)
    }

    @Synchronized
    fun bytesPerSecond(at: Long): Double? {
        val latest = marks.lastOrNull() ?: return null
        val baseline = marks.lastOrNull { it.first <= at - WINDOW_MILLIS } ?: marks.first()
        val span = at - baseline.first
        if (span < MINIMUM_SPAN_MILLIS) return null
        return (latest.second - baseline.second) * 1000.0 / span
    }

    companion object {
        const val WINDOW_MILLIS = 30_000L
        const val MINIMUM_SPAN_MILLIS = 5_000L

        /** "12.3 MB/s" in decimal megabytes, as Android's own storage screens count them. */
        fun speed(bytesPerSecond: Double): String =
            String.format(Locale.ROOT, "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
