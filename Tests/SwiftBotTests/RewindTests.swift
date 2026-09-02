import XCTest
@testable import SwiftBot

final class RewindTests: XCTestCase {
    // MARK: - Tokenizer

    func testTokenizerStripsDiscordNoiseAndLowercases() {
        let content = "GG guys! Check https://example.com/x?a=1 <@123456> <#98765> <:pog:42> nice"
        let words = RewindTokenizer.words(in: content)

        XCTAssertEqual(words, ["gg", "guys", "check", "nice"])
    }

    func testTokenizerKeepsIntraWordApostrophes() {
        XCTAssertEqual(RewindTokenizer.words(in: "don't 'quoted' it's"), ["don't", "quoted", "it's"])
    }

    func testPhraseMatchingRespectsWordBoundaries() {
        // The whole point of matching on tokens: "is" must not hit "island".
        let haystack = RewindTokenizer.words(in: "The island is lovely")
        XCTAssertEqual(RewindTokenizer.occurrences(of: ["is"], in: haystack), 1)
    }

    func testPhraseMatchingIsCaseAndPunctuationInsensitive() {
        let haystack = RewindTokenizer.words(in: "How often IS this asked? how often is it!")
        let needle = RewindTokenizer.phraseTokens("how often is")

        XCTAssertEqual(RewindTokenizer.occurrences(of: needle, in: haystack), 2)
    }

    func testRepeatedPhrasesInOneMessageEachCount() {
        let haystack = RewindTokenizer.words(in: "gg gg gg")
        XCTAssertEqual(RewindTokenizer.occurrences(of: ["gg"], in: haystack), 3)
    }

    func testOverlappingMatchesAreNotDoubleCounted() {
        // "a a a" against "a a" is one match plus a leftover, not two.
        let haystack = RewindTokenizer.words(in: "a a a")
        XCTAssertEqual(RewindTokenizer.occurrences(of: ["a", "a"], in: haystack), 1)
    }

    func testBigramsPairAdjacentWords() {
        XCTAssertEqual(RewindTokenizer.bigrams(from: ["gg", "guys", "nice"]), ["gg guys", "guys nice"])
        XCTAssertEqual(RewindTokenizer.bigrams(from: ["solo"]), [])
    }

    func testEmojiExtractionCoversUnicodeAndCustom() {
        let found = RewindTokenizer.emoji(in: "nice 🎉 work <:pepe:12345>")
        XCTAssertTrue(found.contains("🎉"))
        XCTAssertTrue(found.contains(":pepe:"))
    }

    // MARK: - Store round trip

    func testPhraseReportCountsAcrossUsersAndMessages() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

        await store.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await store.record(message(id: "2", author: "john", text: "GG GUYS!! gg guys", at: day), retainContent: true)
        await store.record(message(id: "3", author: "max", text: "gg guys", at: day), retainContent: true)
        await store.record(message(id: "4", author: "max", text: "unrelated chatter", at: day), retainContent: true)
        await store.flush()

        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )

        XCTAssertEqual(report.totalOccurrences, 4)
        XCTAssertEqual(report.messageCount, 3)
        XCTAssertEqual(report.scannedMessages, 4)
        XCTAssertEqual(report.byUser.first?.userID, "john")
        XCTAssertEqual(report.byUser.first?.count, 3)
    }

    func testPhraseReportHonoursDateRange() async {
        let store = makeStore()
        let inRange = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
        let outOfRange = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01

        await store.record(message(id: "1", author: "john", text: "gg guys", at: inRange), retainContent: true)
        await store.record(message(id: "2", author: "john", text: "gg guys", at: outOfRange), retainContent: true)
        await store.flush()

        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: inRange.addingTimeInterval(-3_600),
            end: inRange.addingTimeInterval(3_600)
        )

        XCTAssertEqual(report.totalOccurrences, 1)
    }

    func testYearSummaryAggregatesWithoutReadingMessageText() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

        // Aggregate-only mode: no text is written, but the counters still land.
        await store.record(message(id: "1", author: "john", text: "hello world hello", at: day), retainContent: false)
        await store.record(message(id: "2", author: "max", text: "hello there", at: day), retainContent: false)
        await store.flush()

        let summary = await store.yearSummary(guildID: "guild-1", year: 2026, filterStopWords: false)

        XCTAssertEqual(summary.totalMessages, 2)
        XCTAssertEqual(summary.totalWords, 5)
        XCTAssertEqual(summary.activeDays, 1)
        XCTAssertEqual(summary.topUsers.first?.userID, "john")
        XCTAssertEqual(summary.topWords.first?.term, "hello")
        XCTAssertEqual(summary.topWords.first?.count, 3)

        // With content retention off there is nothing to scan for a phrase.
        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "hello",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )
        XCTAssertEqual(report.scannedMessages, 0)
    }

    func testStopWordFilteringAppliesToTopWordsOnly() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        await store.record(message(id: "1", author: "john", text: "the the the gg", at: day), retainContent: true)
        await store.flush()

        let filtered = await store.yearSummary(guildID: "guild-1", year: 2026, filterStopWords: true)
        XCTAssertEqual(filtered.topWords.map(\.term), ["gg"])

        let unfiltered = await store.yearSummary(guildID: "guild-1", year: 2026, filterStopWords: false)
        XCTAssertEqual(unfiltered.topWords.first?.term, "the")
    }

    func testImportSkipsMessagesAlreadyStored() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600)
        let batch = [
            message(id: "1", author: "john", text: "gg guys", at: day),
            message(id: "2", author: "max", text: "gg guys", at: day)
        ]

        let first = await store.importMessages(batch, retainContent: true)
        let second = await store.importMessages(batch, retainContent: true)

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0, "Re-running a backfill must top up, not duplicate")

        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )
        XCTAssertEqual(report.totalOccurrences, 2)
    }

    func testPurgeRemovesUserFromTextAndAggregates() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        await store.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await store.record(message(id: "2", author: "max", text: "gg guys", at: day), retainContent: true)
        await store.flush()

        await store.purge(userID: "john", guildID: "guild-1")

        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )
        XCTAssertEqual(report.totalOccurrences, 1)
        XCTAssertEqual(report.byUser.first?.userID, "max")

        let summary = await store.yearSummary(guildID: "guild-1", year: 2026, filterStopWords: false)
        XCTAssertEqual(summary.totalMessages, 1)
        XCTAssertFalse(summary.topUsers.contains { $0.userID == "john" })
    }

    func testUserSummaryReportsRank() async {
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        for index in 0..<3 {
            await store.record(message(id: "j\(index)", author: "john", text: "one two", at: day), retainContent: true)
        }
        await store.record(message(id: "m0", author: "max", text: "solo", at: day), retainContent: true)
        await store.flush()

        let john = await store.userSummary(guildID: "guild-1", userID: "john", year: 2026)
        XCTAssertEqual(john?.messageCount, 3)
        XCTAssertEqual(john?.wordCount, 6)
        XCTAssertEqual(john?.rank, 1)
        XCTAssertEqual(john?.totalRankedUsers, 2)

        let max = await store.userSummary(guildID: "guild-1", userID: "max", year: 2026)
        XCTAssertEqual(max?.rank, 2)

        let missing = await store.userSummary(guildID: "guild-1", userID: "nobody", year: 2026)
        XCTAssertNil(missing)
    }

    func testMessagesSurviveAcrossStoreInstances() async {
        let directory = makeDirectory()
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        let writer = RewindStore(rootURL: directory)
        await writer.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await writer.flush()

        let reader = RewindStore(rootURL: directory)
        let report = await reader.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )

        XCTAssertEqual(report.totalOccurrences, 1)

        let summary = await reader.yearSummary(guildID: "guild-1", year: 2026, filterStopWords: false)
        XCTAssertEqual(summary.totalMessages, 1)
    }

    func testAppendedBatchesShareOneShard() async {
        // Two flushes must append to the same month file, not clobber it.
        let store = makeStore()
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        await store.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await store.flush()
        await store.record(message(id: "2", author: "max", text: "gg guys", at: day), retainContent: true)
        await store.flush()

        let report = await store.phraseReport(
            guildID: "guild-1",
            phrase: "gg guys",
            start: day.addingTimeInterval(-3_600),
            end: day.addingTimeInterval(3_600)
        )
        XCTAssertEqual(report.totalOccurrences, 2)
    }

    func testMonthKeysCoverEveryMonthInRange() {
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        let end = Date(timeIntervalSince1970: 1_782_950_400)   // 2026-07-01

        let keys = RewindCalendar.monthKeys(from: start, to: end)

        XCTAssertEqual(keys.first, "2026-01")
        XCTAssertEqual(keys.last, "2026-07")
        XCTAssertEqual(keys.count, 7)
    }

    // MARK: - File permissions

    func testArchiveFilesAreOwnerOnly() async {
        let directory = makeDirectory()
        let store = RewindStore(rootURL: directory)
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        await store.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await store.flush()

        let manager = FileManager.default
        // `FileManager.enumerator` can't be iterated from an async context, so
        // collect the paths synchronously first.
        let contents = allPaths(under: directory)
        var checked = 0

        for url in contents {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            // Message text must not be readable by other accounts on the box.
            XCTAssertEqual(
                mode,
                isDirectory ? 0o700 : 0o600,
                "\(url.lastPathComponent) is \(String(mode, radix: 8)), expected owner-only"
            )
            checked += 1
        }

        XCTAssertGreaterThan(checked, 0, "Nothing was written, so nothing was actually checked")
    }

    func testTightenPermissionsNarrowsAnExistingArchive() async {
        let directory = makeDirectory()
        let store = RewindStore(rootURL: directory)
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        await store.record(message(id: "1", author: "john", text: "gg guys", at: day), retainContent: true)
        await store.flush()

        // Simulate an archive written before the permissions fix landed.
        let manager = FileManager.default
        let shard = directory
            .appendingPathComponent("guild-1", isDirectory: true)
            .appendingPathComponent("messages-2026-01.jsonl")
        try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: shard.path)

        await store.tightenPermissions()

        let mode = (try? manager.attributesOfItem(atPath: shard.path))?[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "A pre-existing world-readable shard was not narrowed")
    }

    // MARK: - Backup exclusion

    func testBackupExclusionRoundTrips() async {
        let directory = makeDirectory()
        let store = RewindStore(rootURL: directory)

        await store.setBackupExclusion(true)
        let excluded = await store.isExcludedFromBackup()
        XCTAssertTrue(excluded, "The archive should be kept out of Time Machine")

        await store.setBackupExclusion(false)
        let included = await store.isExcludedFromBackup()
        XCTAssertFalse(included)
    }

    func testBackupExclusionCreatesTheArchiveFolderIfMissing() async {
        // The toggle can be flipped before a single message is archived.
        let directory = makeDirectory().appendingPathComponent("not-yet-created", isDirectory: true)
        let store = RewindStore(rootURL: directory)

        await store.setBackupExclusion(true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let excluded = await store.isExcludedFromBackup()
        XCTAssertTrue(excluded)
    }

    // MARK: - Settings gating

    func testSettingsGateBotsChannelsAndOptOuts() {
        var settings = RewindSettings()
        settings.isEnabled = true
        settings.ignoredChannelIDs = ["secret"]
        settings.optedOutUserIDs = ["shy"]

        XCTAssertTrue(settings.collects(channelID: "general"))
        XCTAssertFalse(settings.collects(channelID: "secret"))
        XCTAssertTrue(settings.collects(userID: "john", isBot: false))
        XCTAssertFalse(settings.collects(userID: "shy", isBot: false))
        XCTAssertFalse(settings.collects(userID: "someBot", isBot: true))

        settings.includeBotMessages = true
        XCTAssertTrue(settings.collects(userID: "someBot", isBot: true))

        settings.isEnabled = false
        XCTAssertFalse(settings.collects(channelID: "general"))
        XCTAssertFalse(settings.collects(userID: "john", isBot: false))
    }

    func testCollectionDefaultsToOffAndOutOfBackups() {
        // SwiftBot ships to other operators, so nothing may collect by default.
        let defaults = RewindSettings()
        XCTAssertFalse(defaults.isEnabled)
        XCTAssertTrue(defaults.excludeFromBackups)
    }

    // MARK: - Helpers

    /// Every file and directory beneath `root`, gathered eagerly so the result
    /// can be walked from an async test.
    private nonisolated func allPaths(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return walker.compactMap { $0 as? URL }
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore() -> RewindStore {
        RewindStore(rootURL: makeDirectory())
    }

    private func message(id: String, author: String, text: String, at date: Date) -> RewindMessage {
        RewindMessage(
            id: id,
            guildID: "guild-1",
            channelID: "channel-1",
            authorID: author,
            authorName: author,
            isBot: false,
            content: text,
            createdAt: date
        )
    }
}
