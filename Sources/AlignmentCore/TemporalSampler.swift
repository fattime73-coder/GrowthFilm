import Foundation

/// Selects unique original indices in chronological order. Unknown/non-finite dates
/// are excluded. Endpoints are preserved when at least two images are requested.
public enum TemporalSampler {
    public static func indices(timestamps: [Double?], maximum: Int = 2000) -> [Int] {
        let candidates = timestamps.enumerated().compactMap { index, time -> (index: Int, time: Double)? in
            guard let time, time.isFinite else { return nil }
            return (index, time)
        }.sorted { a, b in a.time == b.time ? a.index < b.index : a.time < b.time }
        let count = min(max(0, maximum), candidates.count)
        guard count > 0 else { return [] }
        if count == candidates.count { return candidates.map(\.index) }
        let first = candidates[0].time, last = candidates[candidates.count - 1].time
        // A single instant has no temporal spacing: spread the selections across
        // the stable input order to avoid taking only the beginning of a burst.
        if first == last {
            if count == 1 { return [candidates[candidates.count / 2].index] }
            return (0..<count).map { i in
                candidates[Int((Double(i) * Double(candidates.count - 1) / Double(count - 1)).rounded())].index
            }
        }
        func nearest(_ target: Double, from lower: Int, through upper: Int) -> Int {
            var lo = lower, hi = upper
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if candidates[mid].time < target { lo = mid + 1 } else { hi = mid }
            }
            if lo > lower && abs(candidates[lo - 1].time - target) <= abs(candidates[lo].time - target) { return lo - 1 }
            return lo
        }
        if count == 1 {
            return [candidates[nearest(first / 2 + last / 2, from: 0, through: candidates.count - 1)].index]
        }
        var result = [candidates[0].index]
        var previous = 0
        for slot in 1..<(count - 1) {
            let fraction = Double(slot) / Double(count - 1)
            let target = first * (1 - fraction) + last * fraction
            // Reserve enough later photos, including the final endpoint. This
            // guarantees an exact count without selecting the same photo twice.
            let upper = candidates.count - count + slot
            let index = nearest(target, from: previous + 1, through: upper)
            result.append(candidates[index].index)
            previous = index
        }
        result.append(candidates[candidates.count - 1].index)
        return result
    }
}
