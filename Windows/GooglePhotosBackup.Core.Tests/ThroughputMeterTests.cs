using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class ThroughputMeterTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 5, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void SpeedIsWhatWasSentOverTheLastHalfMinute()
    {
        var meter = new ThroughputMeter();
        Assert.Null(meter.BytesPerSecond(Start));
        meter.Sent("a", 1_000_000, Start);
        Assert.Null(meter.BytesPerSecond(Start.AddSeconds(2)));
        for (var second = 1; second <= 60; second++)
            meter.Sent("a", 1_000_000 + second * 2_000_000L, Start.AddSeconds(second));
        Assert.Equal(2_000_000, meter.BytesPerSecond(Start.AddSeconds(60))!.Value, precision: 0);
        Assert.Equal(121_000_000, meter.BytesSent);
    }

    [Fact]
    public void ARetriedItemStartsOverWithoutLosingWhatWasSent()
    {
        var meter = new ThroughputMeter();
        meter.Sent("a", 5_000_000, Start);
        meter.Sent("a", 3_000_000, Start.AddSeconds(1));
        Assert.Equal(8_000_000, meter.BytesSent);
        meter.Finished("a", Start.AddSeconds(2));
        meter.Sent("a", 1_000_000, Start.AddSeconds(3));
        Assert.Equal(9_000_000, meter.BytesSent);
    }

    [Fact]
    public void TimeLeftFollowsRecentlyFinishedItems()
    {
        var meter = new ThroughputMeter();
        for (var i = 0; i < 4; i++) meter.Finished("i" + i, Start.AddSeconds(i * 2));
        Assert.Null(meter.SecondsLeft(100, Start.AddSeconds(8)));
        meter.Finished("i4", Start.AddSeconds(8));
        // Five items over 8 s: one every 2 s.
        Assert.Equal(200, meter.SecondsLeft(100, Start.AddSeconds(8))!.Value, precision: 3);
        Assert.Equal(0, meter.SecondsLeft(0, Start.AddSeconds(8)));
    }

    [Theory]
    [InlineData(12_345_678, 840, "12.3 MB/s, about 14 min left")]
    [InlineData(500_000, 30, "0.5 MB/s, less than a minute left")]
    [InlineData(2_000_000, 7_200, "2.0 MB/s, about 2 h left")]
    [InlineData(2_000_000, 4_500, "2.0 MB/s, about 1 h 15 min left")]
    public void DescribesSpeedAndTimeLeft(double bytesPerSecond, double secondsLeft, string expected)
    {
        Assert.Equal(expected, ThroughputMeter.Describe(bytesPerSecond, secondsLeft));
    }

    [Fact]
    public void DescribesNothingUntilThereIsASpeed()
    {
        Assert.Null(ThroughputMeter.Describe(null, 60));
        Assert.Equal("1.0 MB/s", ThroughputMeter.Describe(1_000_000, null));
    }
}
