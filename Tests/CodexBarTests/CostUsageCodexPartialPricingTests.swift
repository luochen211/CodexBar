import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexPartialPricingTests {
    @Test
    func `an unpriced request keeps the priced subtotal of its model day`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "partial.jsonl",
            contents: Self.session(
                day: day,
                env: env,
                id: "partial",
                model: "gpt-5.4",
                inputs: [100_000, 200_000, 300_000]))
        let cache = try Self.scannedCache(day: day, env: env)
        let priced = try #require(Self.report(cache, day: day).data.first?.costUSD)

        var marked = cache
        var usage = try #require(marked.files[file.path])
        usage.codexRows = usage.codexRows?.enumerated().map { index, row in
            var row = row
            if index == 0 { row.unpricedTokens = row.input + row.output }
            return row
        }
        marked.files[file.path] = usage
        let report = Self.report(marked, day: day)
        let entry = try #require(report.data.first)
        let slice = try #require(report.quotaSlices.first { ($0.costUSD ?? 0) > 0 })
        let windowSubtotal: Double = report.quotaSlices.compactMap(\.costUSD).reduce(0, +)

        #expect(priced > 0)
        #expect(abs((entry.costUSD ?? 0) - windowSubtotal) < 1e-9)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.pricedRequestCount == 2)
        #expect(slice.costIsComplete == false)
    }

    @Test
    func `a day with an unpriced model reports incomplete coverage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 10)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "priced.jsonl",
            contents: Self.session(day: day, env: env, id: "priced", model: "gpt-5.4", inputs: [100_000]))
        let other = try env.writeCodexSessionFile(
            day: day,
            filename: "unknown.jsonl",
            contents: Self.session(day: day, env: env, id: "unknown", model: "gpt-5.5", inputs: [100_000]))
        var cache = try Self.scannedCache(day: day, env: env)
        var usage = try #require(cache.files[other.path])
        usage.codexRows = usage.codexRows?.map { row in
            var row = row
            row.unpricedTokens = row.input + row.output
            return row
        }
        cache.files[other.path] = usage
        let entry = try #require(Self.report(cache, day: day).data.first)

        #expect((entry.unpricedRequestCount ?? 0) > 0)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(priced: 1, unpriced: 1))
    }

    private static func scannedCache(day: Date, env: CostUsageTestEnvironment) throws -> CostUsageCache {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        return CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
    }

    private static func report(_ cache: CostUsageCache, day: Date) -> CostUsageDailyReport {
        CostUsageScanner.buildCodexReportFromCache(
            cache: cache,
            range: .init(since: day, until: day),
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
    }

    private static func session(
        day: Date,
        env: CostUsageTestEnvironment,
        id: String,
        model: String,
        inputs: [Int]) throws -> String
    {
        let timestamp = env.isoString(for: day)
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": id]],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": model]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "task_started", "turn_id": "\(id)-turn"]],
        ]
        for input in inputs {
            records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]],
            ]])
        }
        return try env.jsonl(records)
    }
}
