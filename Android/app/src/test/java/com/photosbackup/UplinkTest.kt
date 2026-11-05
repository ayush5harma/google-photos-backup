package com.photosbackup

import com.photosbackup.domain.StagingWindow
import com.photosbackup.domain.ThroughputMeter
import com.photosbackup.domain.UploadParallelism
import com.photosbackup.domain.UploadSample
import org.junit.Assert.*
import org.junit.Test

class UplinkTest {
    /** One batch of 60 MB at [megabytesPerSecond]: over both decision floors up to 15 MB/s. */
    private fun UploadParallelism.at(megabytesPerSecond: Double) =
        measured(UploadSample(bytes = 60_000_000, seconds = 60 / megabytesPerSecond, items = 10))

    private val wifi = UploadParallelism.automatic(UploadParallelism.UNMETERED_CAP)

    @Test
    fun automaticStartsAtFourAndClimbsToTheWifiCap() {
        assertEquals(4, wifi.current)
        assertTrue(wifi.isClimbing)
        var p = wifi
        var rate = 5.0
        for (expected in 5..8) {
            p = p.at(rate)
            rate *= 1.2
            assertEquals(expected, p.current)
        }
        p = p.at(rate)
        assertEquals(8, p.current)
        assertFalse(p.isClimbing)
        assertEquals("8 at a time (the most it uses on this network)", p.summary)
    }

    @Test
    fun oneNoisyStepDoesNotEndTheClimb() {
        var p = wifi.at(10.0).at(12.0) // 4 -> 5 -> 6
        assertEquals(6, p.current)
        p = p.at(11.0) // not 10% over 12: a miss, measured again at 6
        assertEquals(6, p.current)
        assertTrue(p.isClimbing)
        p = p.at(14.0) // over 13.2: the climb goes on
        assertEquals(7, p.current)
        assertTrue(p.isClimbing)
    }

    @Test
    fun aSecondMissReturnsToTheBestLevelAndStays() {
        var p = wifi.at(10.0).at(12.0).at(11.0).at(11.5)
        assertEquals(5, p.current)
        assertFalse(p.isClimbing)
        assertEquals("5 at a time (no faster at 6)", p.summary)
        p = p.at(30.0)
        assertEquals(5, p.current)
    }

    @Test
    fun aRateLimitHalvesAndEndsTheClimb() {
        var p = wifi.at(10.0).at(12.0) // 6
        p = p.measured(UploadSample(0, 3.0, 0, rateLimited = true))
        assertEquals(3, p.current)
        assertFalse(p.isClimbing)
        assertEquals("3 at a time (Google asked to slow down)", p.summary)
        p = p.at(50.0).at(80.0)
        assertEquals(3, p.current)
        p = p.measured(UploadSample(0, 1.0, 0, rateLimited = true))
        p = p.measured(UploadSample(0, 1.0, 0, rateLimited = true))
        assertEquals(1, p.current)
    }

    @Test
    fun onePassingServerErrorIsNoiseTwoTakeOneOff() {
        val p = wifi.at(10.0) // 5
        assertEquals(5, p.measured(UploadSample(30_000_000, 3.0, 10, serverFailures = 1)).current)
        val pushed = p.measured(UploadSample(30_000_000, 3.0, 10, serverFailures = 2))
        assertEquals(4, pushed.current)
        assertFalse(pushed.isClimbing)
    }

    @Test
    fun startUpAndAlreadyBackedUpBatchesAreNotSpeed() {
        assertEquals(
            wifi,
            wifi.measured(UploadSample(30_000_000, 1.0, 10, includesStartUp = true)),
        )
        assertEquals(wifi, wifi.measured(UploadSample(0, 1.0, 0)))
    }

    @Test
    fun smallBatchesAddUpBeforeALevelIsJudged() {
        var p = wifi.measured(UploadSample(10_000_000, 1.0, 3))
        assertEquals(4, p.current)
        p = p.measured(UploadSample(10_000_000, 1.0, 3))
        assertEquals(4, p.current) // 20 MB: under the 24 MB floor
        p = p.measured(UploadSample(10_000_000, 1.0, 3))
        assertEquals(4, p.current) // 30 MB in 3 s: under the 4 s floor
        p = p.measured(UploadSample(10_000_000, 1.0, 3))
        assertEquals(5, p.current)
    }

    @Test
    fun meteredNetworksCapAtTwo() {
        val metered = UploadParallelism.forSetting(UploadParallelism.AUTOMATIC, metered = true)
        assertEquals(2, metered.current)
        assertFalse(metered.isClimbing)
        assertEquals(2, metered.at(5.0).at(50.0).current)
        assertEquals(2, UploadParallelism.forSetting(8, metered = true).current)
        assertEquals(8, UploadParallelism.forSetting(8, metered = false).current)
    }

    @Test
    fun manualIsExactlyTheChosenNumber() {
        for (chosen in 1..8) {
            var p = UploadParallelism.forSetting(chosen, metered = false)
            assertEquals(chosen, p.current)
            p = p.at(5.0).at(50.0).measured(UploadSample(0, 1.0, 0, rateLimited = true))
            assertEquals(chosen, p.current)
        }
        assertEquals(8, UploadParallelism.manual(99, 8).current)
        assertEquals(1, UploadParallelism.manual(0, 8).current)
    }

    @Test
    fun theCapFollowsTheNetworkMidRun() {
        val climbed = wifi.at(10.0).at(12.0).at(14.4) // 7
        assertEquals(7, climbed.current)
        val metered = climbed.recapped(UploadParallelism.METERED_CAP)
        assertEquals(2, metered.current)
        assertEquals(4, metered.recapped(UploadParallelism.UNMETERED_CAP).current)

        val manual = UploadParallelism.manual(6, 8)
        assertEquals(2, manual.recapped(2).current)
        assertEquals(6, manual.recapped(2).recapped(8).current)

        val limited = wifi.at(10.0).at(12.0).measured(UploadSample(0, 1.0, 0, rateLimited = true))
        assertEquals(3, limited.current)
        assertEquals(2, limited.recapped(2).recapped(8).current)
    }

    @Test
    fun stagingStaysWithinTheWindowAndLeavesFreeSpace() {
        val gb = 1_000_000_000L
        assertTrue(StagingWindow.mayStage(0, 900_000_000, 10 * gb))
        assertTrue(StagingWindow.mayStage(400_000_000, 600_000_000, 10 * gb))
        assertFalse(StagingWindow.mayStage(400_000_000, 600_000_001, 10 * gb))
        // A size the provider does not report: allowed while under the window.
        assertTrue(StagingWindow.mayStage(999_999_999, null, 10 * gb))
        assertFalse(StagingWindow.mayStage(gb, null, 10 * gb))
        // The cache volume keeps its floor.
        assertFalse(StagingWindow.mayStage(0, 500_000_000, gb + 499_999_999))
        assertTrue(StagingWindow.mayStage(0, 500_000_000, gb + 500_000_000))
        assertTrue(StagingWindow.mayStage(0, 500_000_000, null))
    }

    @Test
    fun aBatchClosesAtItsCountOrItsBytes() {
        assertFalse(StagingWindow.full(31, 399_999_999))
        assertTrue(StagingWindow.full(32, 0))
        assertTrue(StagingWindow.full(1, 400_000_000))
    }

    @Test
    fun largestFirstKeepsTheOrderOfEqualSizes() {
        val sizes = mapOf("a" to 1L, "b" to 9L, "c" to 1L, "d" to 5L)
        assertEquals(listOf("b", "d", "a", "c"), StagingWindow.largestFirst(listOf("a", "b", "c", "d")) { sizes.getValue(it) })
    }

    @Test
    fun throughputIsTheLastHalfMinuteOfBytesSent() {
        val meter = ThroughputMeter()
        meter.sent("a", 1_000_000, at = 0)
        meter.sent("a", 3_000_000, at = 2_000)
        assertNull("no speed before five seconds", meter.bytesPerSecond(at = 4_000))
        meter.sent("b", 2_000_000, at = 5_000)
        assertEquals(800_000.0, meter.bytesPerSecond(at = 5_000)!!, 0.001)
        // A retry starts the item over: its bytes count again, not negatively.
        meter.sent("b", 1_000_000, at = 6_000)
        assertEquals(6_000_000, meter.bytesSent)
        // Old marks leave the window.
        meter.sent("c", 30_000_000, at = 60_000)
        assertEquals(30_000_000 * 1000.0 / 54_000, meter.bytesPerSecond(at = 60_000)!!, 0.001)
        meter.finished("c")
        meter.sent("c", 1_000_000, at = 61_000)
        assertEquals(37_000_000, meter.bytesSent)
        assertEquals("12.3 MB/s", ThroughputMeter.speed(12_345_678.0))
    }
}
