import Foundation

/// Pure level math shared by the audio sources. No state, safe to call from a
/// real-time render thread: no heap allocation, no locks.
enum LevelAnalysis {
    /// Slices are capped here regardless of how long the buffer is, widening
    /// each slice instead of growing the count past this.
    static let maxSlices = 64

    /// Converts a linear RMS amplitude (0...1) to dBFS. Shared so every caller
    /// applies the same floor instead of copying the formula: `ProcessTapSource`
    /// computes its own RMS (its samples arrive as a list of discontiguous
    /// buffers, not one contiguous span this type could take directly) but
    /// still converts through here.
    static func dBFS(rms: Double) -> Float {
        Float(20 * log10(max(rms, 1e-9)))
    }

    /// Plain RMS across a buffer of samples, in dBFS.
    static func rmsDBFS(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard samples.count > 0 else { return LevelMeter.silence }
        var sumSquares: Double = 0
        for sample in samples {
            let value = Double(sample)
            sumSquares += value * value
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        return dBFS(rms: rms)
    }

    /// The level a *sustained* sound reaches, as opposed to a brief one.
    ///
    /// A whole-buffer RMS is an energy average: a 20ms keyboard click sitting
    /// in an otherwise silent 100ms buffer still drags the average RMS tens of
    /// dB above the floor, because the math is dominated by whatever sample is
    /// loudest. Splitting the buffer into slices and taking the *median* fixes
    /// that: a click fills 1-3 of 10 slices, so the median stays at the floor,
    /// while speech - which fills most of the buffer - keeps its level. Using
    /// the upper-median index (5 of 10, not 4) means the boundary is "at least
    /// half the slices are loud", not "more than half".
    ///
    /// Falls back to plain RMS when the buffer is too short to slice
    /// meaningfully (`minimumSlices`), so short or unusual buffer sizes still
    /// get a sensible level instead of being skipped.
    static func sustainedDBFS(
        _ samples: UnsafeBufferPointer<Float>,
        sliceLength: Int,
        percentile: Double = 0.5,
        minimumSlices: Int = 3
    ) -> Float {
        guard sliceLength > 0, samples.count > 0 else { return rmsDBFS(samples) }

        let naiveSliceCount = samples.count / sliceLength
        guard naiveSliceCount >= minimumSlices else { return rmsDBFS(samples) }

        // Cap the slice count, widening each slice rather than growing past it,
        // so an unexpectedly long buffer can't blow past the stack allocation.
        let sliceCount = min(naiveSliceCount, maxSlices)
        let widenedLength = samples.count / sliceCount

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: sliceCount) { (levels: UnsafeMutableBufferPointer<Float>) in
            var levels = levels
            for slice in 0..<sliceCount {
                let start = slice * widenedLength
                // The last slice absorbs any remainder from integer division.
                let end = slice == sliceCount - 1 ? samples.count : start + widenedLength
                let sliceSamples = UnsafeBufferPointer(rebasing: samples[start..<end])
                levels[slice] = rmsDBFS(sliceSamples)
            }
            levels.sort()
            let index = Int((Double(sliceCount - 1) * percentile).rounded())
            return levels[index]
        }
    }
}
