using GooglePhotosBackup.Core;
using Xunit;

namespace GooglePhotosBackup.Core.Tests;

public sealed class UploadParallelismTests
{
    // One decision's worth at a given speed: 24 MB over 4 s is 6 MB/s.
    private static UploadSample At(double bytesPerSecond, double seconds = 4) =>
        new((long)(bytesPerSecond * seconds), seconds, Items: 10, RateLimited: false, ServerFailures: 0);

    [Fact]
    public void AutomaticStartsAtFourAndClimbsWhileEachStepIsTenPercentFaster()
    {
        var parallelism = UploadParallelism.Automatic();
        Assert.Equal(4, parallelism.Current);
        Assert.True(parallelism.IsClimbing);
        var rate = 6_000_000.0;
        for (var expected = 5; expected <= UploadParallelism.MaximumThreads; expected++)
        {
            parallelism.Measured(At(rate));
            Assert.Equal(expected, parallelism.Current);
            rate *= 1.2;
        }
        parallelism.Measured(At(rate));
        Assert.Equal(32, parallelism.Current);
        Assert.False(parallelism.IsClimbing);
        Assert.Equal("32 at a time (the most it uses)", parallelism.Summary);
    }

    [Fact]
    public void OneNoisyStepDoesNotLockTheLevel()
    {
        var parallelism = UploadParallelism.Automatic();
        parallelism.Measured(At(6_000_000));        // 4 -> 5
        parallelism.Measured(At(7_000_000));        // 5 -> 6
        parallelism.Measured(At(6_500_000));        // 6 no faster: measured again, still 6
        Assert.Equal(6, parallelism.Current);
        Assert.True(parallelism.IsClimbing);
        Assert.Equal("6 at a time, checking again", parallelism.Summary);
        parallelism.Measured(At(8_000_000));        // 6 really is faster: climb on
        Assert.Equal(7, parallelism.Current);
        Assert.True(parallelism.IsClimbing);
    }

    [Fact]
    public void TwoNonImprovingMeasurementsSettleOnTheBestLevel()
    {
        var parallelism = UploadParallelism.Automatic();
        parallelism.Measured(At(6_000_000));        // 4 -> 5, best 4
        parallelism.Measured(At(7_000_000));        // 5 -> 6, best 5
        parallelism.Measured(At(7_100_000));        // 6 miss
        parallelism.Measured(At(7_200_000));        // 6 miss again: back to 5
        Assert.Equal(5, parallelism.Current);
        Assert.False(parallelism.IsClimbing);
        Assert.Equal("5 at a time (no faster at 6)", parallelism.Summary);
        parallelism.Measured(At(50_000_000));
        Assert.Equal(5, parallelism.Current);
    }

    [Fact]
    public void ARateLimitHalvesAndEndsTheClimbForTheRun()
    {
        var parallelism = UploadParallelism.Automatic();
        for (var i = 0; i < 6; i++) parallelism.Measured(At(6_000_000 * Math.Pow(1.2, i)));
        Assert.Equal(10, parallelism.Current);
        parallelism.Measured(new UploadSample(0, 1, 0, RateLimited: true, ServerFailures: 0));
        Assert.Equal(5, parallelism.Current);
        Assert.False(parallelism.IsClimbing);
        Assert.Equal("5 at a time (Google asked to slow down)", parallelism.Summary);
        parallelism.Measured(At(90_000_000));
        Assert.Equal(5, parallelism.Current);
        parallelism.Measured(new UploadSample(0, 1, 0, true, 0));
        parallelism.Measured(new UploadSample(0, 1, 0, true, 0));
        parallelism.Measured(new UploadSample(0, 1, 0, true, 0));
        Assert.Equal(1, parallelism.Current);
    }

    [Fact]
    public void RepeatedServerFailuresTakeOneOffButOnePassingFailureDoesNot()
    {
        var parallelism = UploadParallelism.Automatic();
        parallelism.Measured(At(6_000_000) with { ServerFailures = 1 });
        Assert.Equal(5, parallelism.Current);
        parallelism.Measured(new UploadSample(0, 1, 3, RateLimited: false, ServerFailures: 2));
        Assert.Equal(4, parallelism.Current);
        Assert.False(parallelism.IsClimbing);
        Assert.Equal("4 at a time (Google had trouble keeping up)", parallelism.Summary);
    }

    [Fact]
    public void StartUpAlreadyKnownItemsAndSmallSamplesDoNotDecide()
    {
        var parallelism = UploadParallelism.Automatic();
        parallelism.Measured(At(6_000_000) with { IncludesStartUp = true });
        parallelism.Measured(At(6_000_000) with { Items = 0 });
        Assert.Equal(4, parallelism.Current);
        // Two small batches add up to one decision.
        parallelism.Measured(new UploadSample(12_000_000, 2, 5, false, 0));
        Assert.Equal(4, parallelism.Current);
        parallelism.Measured(new UploadSample(12_000_000, 2, 5, false, 0));
        Assert.Equal(5, parallelism.Current);
    }

    [Fact]
    public void ManualUsesExactlyTheChosenNumberWhateverHappens()
    {
        foreach (var chosen in new[] { 1, 2, 7, 16, 32 })
        {
            var parallelism = UploadParallelism.Manual(chosen);
            Assert.Equal(chosen, parallelism.Current);
            Assert.False(parallelism.IsClimbing);
            parallelism.Measured(At(6_000_000));
            parallelism.Measured(At(60_000_000));
            parallelism.Measured(new UploadSample(0, 1, 0, RateLimited: true, ServerFailures: 5));
            Assert.Equal(chosen, parallelism.Current);
            Assert.Equal($"{chosen} at a time (chosen in Settings)", parallelism.Summary);
        }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(33)]
    public void ManualRefusesANumberOutsideTheBridgeRange(int threads)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => UploadParallelism.Manual(threads));
    }

    [Theory]
    [InlineData("503 Server Error: Service Unavailable for url: https://x/1234", null, FailureClass.Retryable)]
    [InlineData("429 Client Error: Too Many Requests", null, FailureClass.RateLimited)]
    [InlineData("too many 429 error responses", true, FailureClass.RateLimited)]
    [InlineData("Too Many Requests", false, FailureClass.RateLimited)]
    [InlineData("HTTPSConnectionPool: Read timed out.", false, FailureClass.Retryable)]
    [InlineData("400 Client Error: Bad Request for url: https://x/500", true, FailureClass.Permanent)]
    [InlineData("gpmc returned no media key", true, FailureClass.Retryable)]
    [InlineData("gpmc returned no media key", null, FailureClass.Permanent)]
    [InlineData(null, true, FailureClass.Retryable)]
    public void FailuresAreClassifiedLikeTheMac(string? message, bool? retryable, FailureClass expected)
    {
        Assert.Equal(expected, FailureClassifier.Classify(message, retryable));
    }
}
