import Foundation
import HealthKit

enum ImportError: LocalizedError {
    case healthUnavailable
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .healthUnavailable:
            return "Health data isn’t available on this device."
        case .authorizationDenied:
            return "Permission to write weight data was denied. Enable it in Settings → Health → Data Access & Devices → WeightImporter."
        }
    }
}

final class HealthKitManager {
    let store = HKHealthStore()
    let bodyMass = HKQuantityType(.bodyMass)

    /// Key = sample start time truncated to the minute (epoch seconds / 60).
    /// Absolute, so time zones only matter when the parser interprets the CSV text.
    typealias MinuteKey = Int
    static func minuteKey(_ d: Date) -> MinuteKey { Int(floor(d.timeIntervalSince1970 / 60)) }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ImportError.healthUnavailable }
        try await store.requestAuthorization(toShare: [bodyMass], read: [bodyMass])
        guard store.authorizationStatus(for: bodyMass) == .sharingAuthorized else {
            throw ImportError.authorizationDenied
        }
    }

    /// One query over the whole span. Returns the set of minutes holding ANY body-mass
    /// sample, plus this app's own samples grouped by minute (the only ones we may delete).
    func existingMinutes(from start: Date, to end: Date) async throws
        -> (anySource: Set<MinuteKey>, own: [MinuteKey: [HKQuantitySample]]) {

        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: bodyMass,
                                  predicate: pred,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: (result as? [HKQuantitySample]) ?? [])
                }
            }
            store.execute(q)
        }

        var any = Set<MinuteKey>()
        var own: [MinuteKey: [HKQuantitySample]] = [:]
        let me = HKSource.default()
        for s in samples {
            let k = Self.minuteKey(s.startDate)
            any.insert(k)
            if s.sourceRevision.source == me { own[k, default: []].append(s) }
        }
        return (any, own)
    }

    func delete(_ samples: [HKObject]) async throws {
        guard !samples.isEmpty else { return }
        try await store.delete(samples)
    }

    func makeSamples(_ rows: [WeightRow]) -> [HKQuantitySample] {
        rows.map { row in
            HKQuantitySample(type: bodyMass,
                             quantity: HKQuantity(unit: .pound(), doubleValue: row.pounds),
                             start: row.date,
                             end: row.date,
                             metadata: ["CSVImport": true])
        }
    }

    func save(_ objects: [HKQuantitySample]) async throws {
        guard !objects.isEmpty else { return }
        try await store.save(objects)
    }
}
