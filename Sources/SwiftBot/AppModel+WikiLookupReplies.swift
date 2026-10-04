import Foundation

/// A Lookup answer ready for Discord: the card and its buttons, or a short
/// message when there is nothing to show.
struct WikiLookupReply {
    var content: String?
    var embeds: [[String: Any]] = []
    var components: [[String: Any]] = []
    /// Plain-text version of a single card, for when an embed can't be sent.
    var fallbackText: String?

    var found: Bool { !embeds.isEmpty }

    var payload: [String: Any] {
        var payload: [String: Any] = [:]
        if let content { payload["content"] = String(content.prefix(1900)) }
        if !embeds.isEmpty { payload["embeds"] = embeds }
        // Always sent, so an edited message drops buttons it no longer needs.
        payload["components"] = components
        return payload
    }
}

/// Lines two lookups up stat by stat and marks the better value where the
/// stat's direction is known ("Damage" higher, "Reload" lower).
enum WikiStatComparison {
    enum Side: Equatable { case left, right }

    struct Row: Equatable {
        let name: String
        let left: String?
        let right: String?
        let winner: Side?
    }

    /// Stats where less is better. Checked before the higher list, so
    /// "Reload Speed" and "Use Time" read as lower-is-better.
    private static let lowerIsBetter = [
        "reload", "cooldown", "cool down", "recoil", "spread", "weight", "use time",
        "delay", "charge time", "equip", "fp cost", "mastery rank", "deploy"
    ]
    private static let higherIsBetter = [
        "damage", "dps", "fire rate", "firerate", "rate of fire", "rpm", "magazine", "mag size",
        "ammo", "capacity", "range", "dropoff", "health", "hp", "armor", "armour", "durability",
        "crit", "critical", "velocity", "knockback", "multishot", "accuracy", "punch", "stun",
        "speed", "efficiency", "enchantability", "headshot", "phys", "magic", "fire", "ltng",
        "lightning", "holy", "attack"
    ]

    static func rows(left: [WikiResultField], right: [WikiResultField], limit: Int = 24) -> [Row] {
        func key(_ name: String) -> String { WikiAlias.key(name) }
        let rightByKey = Dictionary(right.map { (key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let leftKeys = Set(left.map { key($0.name) })

        var shared: [Row] = []
        var leftOnly: [Row] = []
        for field in left {
            if let match = rightByKey[key(field.name)] {
                shared.append(Row(name: field.name, left: field.value, right: match.value,
                                  winner: winner(name: field.name, left: field.value, right: match.value)))
            } else {
                leftOnly.append(Row(name: field.name, left: field.value, right: nil, winner: nil))
            }
        }
        let rightOnly = right.filter { !leftKeys.contains(key($0.name)) }
            .map { Row(name: $0.name, left: nil, right: $0.value, winner: nil) }
        return Array((shared + leftOnly + rightOnly).prefix(limit))
    }

    static func winner(name: String, left: String, right: String) -> Side? {
        guard let higher = higherIsBetter(name),
              let lhs = number(in: left), let rhs = number(in: right), lhs != rhs else { return nil }
        return (lhs > rhs) == higher ? .left : .right
    }

    static func higherIsBetter(_ name: String) -> Bool? {
        let lowered = name.lowercased()
        if lowerIsBetter.contains(where: lowered.contains) { return false }
        if higherIsBetter.contains(where: lowered.contains) { return true }
        return nil
    }

    /// The first number in a value: "2.00 s" → 2, "1,561" → 1561, "JE: 7 HP" → 7.
    static func number(in value: String) -> Double? {
        guard let range = value.range(of: #"-?\d[\d,]*(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(value[range].replacingOccurrences(of: ",", with: ""))
    }

    /// Splits "akm vs fcar" (also "versus", "vs.") into the two things to compare.
    static func splitVersus(_ query: String) -> (String, String)? {
        guard let range = query.range(of: #"\s+(vs\.?|versus)\s+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let left = query[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let right = query[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }
}

extension AppModel {
    static let wikiAlternativesCustomIDPrefix = "wiki:alt:"
    static let wikiPickCustomIDPrefix = "wiki:pick:"

    // MARK: - Building replies

    /// The answer to one Lookup command, from Discord's slash or prefix form.
    /// `versus` comes from the slash `vs` option; prefix commands write
    /// "akm vs fcar" in the query instead.
    func wikiLookupReply(command: WikiCommand, source: WikiSource, query: String, versus: String? = nil) async -> WikiLookupReply {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = normalizedWikiCommandTrigger(command.trigger)
        let usage = trigger.isEmpty ? command.trigger : "/\(trigger)"
        guard !trimmed.isEmpty else {
            return WikiLookupReply(content: "📘 Usage: \(usage) <item> — or compare two with \(usage) <item> vs <item>")
        }
        guard let resolved = resolveWikiSourceAndQuery(defaultSource: source, query: trimmed) else {
            return WikiLookupReply(content: "⚠️ No Lookup sources are enabled. Add or enable a source in Lookup settings.")
        }
        let target = resolved.source
        guard !resolved.query.isEmpty else {
            return WikiLookupReply(content: "📘 Add what to look up after the source. Example: \(usage) \(target.name)::AKM")
        }

        let versusQuery = versus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pair: (String, String)? = versusQuery.isEmpty
            ? WikiStatComparison.splitVersus(resolved.query)
            : (resolved.query, versusQuery)
        if let (leftQuery, rightQuery) = pair {
            async let leftLookup = runWikiLookup(source: target, query: leftQuery)
            async let rightLookup = runWikiLookup(source: target, query: rightQuery)
            let (left, right) = await (leftLookup, rightLookup)
            guard let left, let right else {
                let missing = [left == nil ? leftQuery : nil, right == nil ? rightQuery : nil].compactMap { $0 }
                let list = missing.map { "\"\($0)\"" }.joined(separator: " or ")
                return WikiLookupReply(content: "❌ I couldn't find \(list) on \(target.name).")
            }
            return WikiLookupReply(
                embeds: [wikiCompareEmbed(source: target, left: left, right: right)],
                components: wikiLinkButtons([left, right])
            )
        }

        guard let result = await runWikiLookup(source: target, query: resolved.query) else {
            return WikiLookupReply(content: "❌ I couldn't find a page on \(target.name) for \"\(resolved.query)\".")
        }
        return wikiCardReply(source: target, query: resolved.query, result: result)
    }

    func wikiCardReply(source: WikiSource, query: String, result: FinalsWikiLookupResult) -> WikiLookupReply {
        var buttons = wikiLinkButtons([result]).first?["components"] as? [[String: Any]] ?? []
        buttons.append([
            "type": 2,
            "style": 2,
            "label": "Not this one?",
            "custom_id": Self.wikiAlternativesCustomID(sourceID: source.id, query: query)
        ])
        return WikiLookupReply(
            embeds: [wikiEmbed(source: source, result: result)],
            components: [["type": 1, "components": buttons]],
            fallbackText: formattedWikiResponse(source: source, result: result)
        )
    }

    /// "Open on wiki" link buttons, one per page.
    private func wikiLinkButtons(_ results: [FinalsWikiLookupResult]) -> [[String: Any]] {
        let buttons: [[String: Any]] = results.compactMap { result in
            guard let url = URL(string: result.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  result.url.count <= 512 else { return nil }
            let label = results.count > 1 ? "Open \(result.title)" : "Open on wiki"
            return ["type": 2, "style": 5, "label": String(label.prefix(80)), "url": result.url]
        }
        return buttons.isEmpty ? [] : [["type": 1, "components": buttons]]
    }

    /// custom_id is capped at 100 characters, so the query is trimmed to fit.
    static func wikiAlternativesCustomID(sourceID: UUID, query: String) -> String {
        let prefix = "\(wikiAlternativesCustomIDPrefix)\(sourceID.uuidString):"
        return prefix + String(query.prefix(100 - prefix.count))
    }

    func wikiCompareEmbed(source: WikiSource, left: FinalsWikiLookupResult, right: FinalsWikiLookupResult) -> [String: Any] {
        func statFields(_ result: FinalsWikiLookupResult) -> [WikiResultField] {
            let embed = wikiEmbed(source: source, result: result)
            return ((embed["fields"] as? [[String: Any]]) ?? []).compactMap { raw in
                guard let name = raw["name"] as? String, let value = raw["value"] as? String,
                      name != "Notes", value != "-" else { return nil }
                return WikiResultField(name: name, value: value)
            }
        }
        let rows = WikiStatComparison.rows(left: statFields(left), right: statFields(right))
        func cell(_ value: String?, wins: Bool) -> String {
            guard let value else { return "—" }
            let short = String(value.prefix(60))
            return wins ? "**\(short)**" : short
        }

        var description = "[\(left.title)](\(left.url)) vs [\(right.title)](\(right.url))"
        if rows.isEmpty {
            description += "\n\nNeither page has stats to line up."
        } else if rows.contains(where: { $0.winner != nil }) {
            description += "\nThe better value is in **bold**."
        }
        var embed: [String: Any] = [
            "title": String("\(left.title) vs \(right.title)".prefix(256)),
            "description": description,
            "color": 0x5865F2,
            "footer": ["text": source.name]
        ]
        if !rows.isEmpty {
            embed["fields"] = rows.map { row -> [String: Any] in
                [
                    "name": String(row.name.prefix(256)),
                    "value": "\(cell(row.left, wins: row.winner == .left)) · \(cell(row.right, wins: row.winner == .right))",
                    "inline": true
                ]
            }
        }
        return embed
    }

    /// One lookup as people asked it: applies the source's aliases, records
    /// the outcome for the Lookup pages, and feeds the AI's wiki context.
    func runWikiLookup(source: WikiSource, query: String) async -> FinalsWikiLookupResult? {
        let result = await cluster.lookupWiki(query: source.resolvingAlias(query), source: source)
        updateWikiBridgeSourceRuntimeState(id: source.id) { entry in
            entry.lastLookupAt = Date()
            entry.lastStatus = result.map { "Resolved: \($0.title)" } ?? "No match for \"\(query)\""
        }
        persistSettingsQuietly()
        if let result {
            await wikiContextCache.store(sourceName: source.name, query: query, result: result)
        }
        await wikiUsageStore.record(sourceID: source.id, query: query, title: result?.title)
        await refreshWikiUsageSummaries()
        return result
    }

    func refreshWikiUsageSummaries() async {
        wikiUsageSummaries = await wikiUsageStore.summaries()
    }

    // MARK: - Slash commands, autocomplete and buttons

    /// A Lookup slash command. The reply is the card itself (it used to post
    /// the card separately and answer with "✅ Completed").
    func handleWikiSlash(event: GatewayInteractionCreateEvent, context: SlashContext, resolved: ResolvedWikiCommand) async {
        let name = (event.commandName ?? "").lowercased()
        let blocked: String? = {
            if !(settings.commandsEnabled && settings.slashCommandsEnabled) { return "Slash commands are turned off in SwiftBot settings." }
            if !isCommandEnabled(name: name, surface: "slash") { return "`/\(name)` is turned off in command settings." }
            if !settings.wikiBot.isEnabled { return "Lookup is turned off." }
            return nil
        }()
        if let blocked {
            try? await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 4, "data": ["content": blocked, "flags": 64]]
            )
            return
        }
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 5]
            )
        } catch {
            logs.append("❌ Failed ACK for /\(name): \(error.localizedDescription)")
            return
        }

        let reply = await wikiLookupReply(
            command: resolved.command,
            source: resolved.source,
            query: slashOptionString(named: "query", in: event.data) ?? "",
            versus: slashOptionString(named: "vs", in: event.data)
        )
        stats.commandsRun += 1
        let execution = await commandExecutionDetails(for: name)
        addCommandLogEntry(CommandLogEntry(
            time: Date(),
            user: context.username,
            server: commandServerName(from: context.rawLikeMessage),
            command: formatSlashCommandForLog(name: name, data: event.data),
            channel: context.channelId,
            executionRoute: execution.route,
            executionNode: execution.node,
            ok: reply.found
        ))
        await editWikiInteraction(event: event, payload: reply.payload)
    }

    /// Suggests page titles while someone types a Lookup command's `query`
    /// or `vs`. With nothing typed yet, offers the source's most-asked items.
    func handleWikiAutocomplete(event: GatewayInteractionCreateEvent) async {
        var choices: [[String: Any]] = []
        if settings.wikiBot.isEnabled,
           let resolved = resolveWikiCommand(named: event.commandName ?? ""),
           let focused = focusedOptionValue(in: event.data) {
            var source = resolved.source
            var typed = focused
            var selector = ""
            if focused.contains("::"), let explicit = resolveWikiSourceAndQuery(defaultSource: source, query: focused) {
                source = explicit.source
                typed = explicit.query
                selector = String(focused[..<(focused.range(of: "::")?.upperBound ?? focused.startIndex)])
            }
            let titles = await wikiAutocompleteTitles(source: source, typed: typed)
            choices = titles.prefix(25).map { title in
                let value = String((selector + title).prefix(100))
                return ["name": String(title.prefix(100)), "value": value]
            }
        }
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 8, "data": ["choices": choices]]
            )
        } catch {
            // Autocomplete answers expire after three seconds; a late one is harmless.
        }
    }

    func wikiAutocompleteTitles(source: WikiSource, typed: String) async -> [String] {
        let typedKey = WikiAlias.key(typed)
        var titles: [String] = []
        if typedKey.isEmpty {
            titles = wikiUsageSummaries[source.id]?.topItems.map(\.title) ?? []
        } else {
            titles = source.aliases
                .filter { WikiAlias.key($0.from).hasPrefix(typedKey) }
                .map(\.to)
            titles += await wikiLookupService.suggestTitles(prefix: typed, source: source, limit: 20)
        }
        var seen: Set<String> = []
        return titles.filter { !$0.isEmpty && seen.insert(WikiAlias.key($0)).inserted }
    }

    private func focusedOptionValue(in data: [String: DiscordJSON]) -> String? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option, case .bool(true)? = map["focused"] else { continue }
            if case let .string(value)? = map["value"] { return value }
            return ""
        }
        return nil
    }

    func handleWikiComponentInteraction(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let customID = slashCustomID(in: event.data)
        if customID.hasPrefix(Self.wikiAlternativesCustomIDPrefix) {
            await showWikiAlternatives(event: event, customID: customID)
        } else if customID.hasPrefix(Self.wikiPickCustomIDPrefix) {
            await postPickedWikiPage(event: event, context: context, customID: customID)
        }
    }

    /// "Not this one?": a private list of other pages the query could mean.
    private func showWikiAlternatives(event: GatewayInteractionCreateEvent, customID: String) async {
        let rest = customID.dropFirst(Self.wikiAlternativesCustomIDPrefix.count)
        let sourceID = UUID(uuidString: String(rest.prefix(36)))
        let query = String(rest.dropFirst(37))
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 5, "data": ["flags": 64]]
            )
        } catch {
            logs.append("❌ Failed ACK for Lookup alternatives: \(error.localizedDescription)")
            return
        }
        guard let source = settings.wikiBot.sources.first(where: { $0.id == sourceID && $0.enabled }) else {
            await editWikiInteraction(event: event, payload: ["content": "That Lookup source is no longer available."])
            return
        }

        let shownKey = WikiAlias.key(shownEmbedTitle(in: event.rawMap) ?? "")
        let titles = await wikiLookupService.searchTitles(query: source.resolvingAlias(query), source: source, limit: 12)
            .filter { title in
                let key = WikiAlias.key(title)
                return !key.isEmpty && key != shownKey && !(shownKey.hasPrefix(key) && key.count >= 3)
            }
            .prefix(10)
        guard !titles.isEmpty else {
            await editWikiInteraction(event: event, payload: ["content": "No other pages on \(source.name) match \"\(query)\"."])
            return
        }
        let menu: [String: Any] = [
            "type": 3,
            "custom_id": "\(Self.wikiPickCustomIDPrefix)\(source.id.uuidString)",
            "placeholder": String("Other matches for \"\(query)\"".prefix(150)),
            "options": titles.map { ["label": String($0.prefix(100)), "value": String($0.prefix(100))] }
        ]
        await editWikiInteraction(event: event, payload: [
            "content": "Pick the page you meant, and I'll post it.",
            "components": [["type": 1, "components": [menu]]]
        ])
    }

    /// A page picked from the "Not this one?" list: posted to the channel,
    /// and the private list updated to say so.
    private func postPickedWikiPage(event: GatewayInteractionCreateEvent, context: SlashContext, customID: String) async {
        let sourceID = UUID(uuidString: String(customID.dropFirst(Self.wikiPickCustomIDPrefix.count)))
        guard let title = slashComponentValues(in: event.data).first else { return }
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: ["type": 6]
            )
        } catch {
            logs.append("❌ Failed ACK for Lookup pick: \(error.localizedDescription)")
            return
        }
        guard let source = settings.wikiBot.sources.first(where: { $0.id == sourceID && $0.enabled }),
              let result = await runWikiLookup(source: source, query: title) else {
            await editWikiInteraction(event: event, payload: ["content": "I couldn't load \"\(title)\".", "components": []])
            return
        }
        let reply = wikiCardReply(source: source, query: title, result: result)
        let posted = await sendPayload(channelId: context.channelId, payload: reply.payload, action: "sendMessage(wiki-pick)")
        await editWikiInteraction(event: event, payload: [
            "content": posted ? "Posted **\(result.title)**." : "I couldn't post **\(result.title)** here.",
            "components": []
        ])
    }

    private func shownEmbedTitle(in raw: [String: DiscordJSON]) -> String? {
        guard case let .object(message)? = raw["message"],
              case let .array(embeds)? = message["embeds"],
              case let .object(first)? = embeds.first,
              case let .string(title)? = first["title"] else { return nil }
        return title
    }

    private func editWikiInteraction(event: GatewayInteractionCreateEvent, payload: [String: Any]) async {
        guard let applicationID = botUserId, !applicationID.isEmpty else { return }
        guard ActionDispatcher.canSend(clusterMode: runtimeClusterMode, action: "editOriginalInteractionResponse", log: { logs.append($0) }) else { return }
        // Same pattern as the generic slash path: the dictionary is built here
        // and handed off once.
        nonisolated(unsafe) let payload = payload
        do {
            try await service.editOriginalInteractionResponse(
                applicationID: applicationID,
                interactionToken: event.interactionToken,
                payload: payload
            )
        } catch {
            logs.append("❌ Failed editing Lookup reply: \(error.localizedDescription)")
        }
    }

    // MARK: - Answering questions in chat

    /// When someone asks the AI about an item ("what's the AKM damage?"),
    /// looks it up first so the answer uses the wiki's numbers. Returns an
    /// empty string when the message doesn't name anything a source has.
    func proactiveWikiContext(for prompt: String) async -> String {
        guard settings.wikiBot.isEnabled, settings.wikiBot.answersQuestions,
              let query = Self.wikiQuestionSubject(in: prompt) else { return "" }
        let promptKey = WikiAlias.key(prompt)
        // A source the message names ("in terraria") goes first.
        let enabled = orderedEnabledWikiSources()
        let isNamed = { (source: WikiSource) in
            promptKey.contains(WikiAlias.key(source.name.replacingOccurrences(of: "Wiki", with: "")))
        }
        let sources = (enabled.filter(isNamed) + enabled.filter { !isNamed($0) }).prefix(2)

        for source in sources {
            let aliased = source.resolvingAlias(query)
            var title: String? = aliased != query ? aliased : nil
            if title == nil {
                title = await wikiLookupService.searchTitles(query: query, source: source, limit: 3)
                    .first { candidate in
                        let key = WikiAlias.key(candidate)
                        return key.count >= 2 && promptKey.contains(key)
                    }
            }
            guard let title, let result = await cluster.lookupWiki(query: title, source: source) else { continue }
            await wikiContextCache.store(sourceName: source.name, query: query, result: result)
            return renderLiveWikiContext(source: source, result: result)
        }
        return ""
    }

    private func renderLiveWikiContext(source: WikiSource, result: FinalsWikiLookupResult) -> String {
        let embed = wikiEmbed(source: source, result: result)
        let stats = ((embed["fields"] as? [[String: Any]]) ?? []).compactMap { raw -> String? in
            guard let name = raw["name"] as? String, let value = raw["value"] as? String, value != "-" else { return nil }
            return "\(name): \(value)"
        }
        var lines = ["Lookup result from \(source.name) for this question (use these numbers):", "\(result.title) — \(result.url)"]
        let summary = summarizedWikiExtract(result.extract, limit: 300)
        if !summary.isEmpty { lines.append(summary) }
        if !stats.isEmpty { lines.append("Stats: " + stats.prefix(18).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    private static let questionWords: Set<String> = [
        "what", "whats", "how", "which", "is", "does", "do", "tell", "stats", "stat", "damage",
        "dps", "reload", "magazine", "ammo", "durability", "recipe", "craft", "drop", "drops",
        "health", "hp", "range", "headshot", "crit", "weight", "price", "cost", "firerate", "rpm"
    ]
    private static let fillerWords: Set<String> = [
        "what", "whats", "what's", "is", "are", "the", "a", "an", "of", "how", "much", "many", "does",
        "do", "on", "in", "for", "with", "and", "me", "tell", "about", "it", "its", "it's", "stats",
        "stat", "damage", "dps", "reload", "magazine", "mag", "ammo", "durability", "recipe", "craft",
        "drop", "drops", "health", "hp", "range", "headshot", "crit", "weight", "price", "cost",
        "firerate", "fire", "rate", "rpm", "time", "speed", "get", "make", "i", "you", "can", "should",
        "which", "better", "best", "good", "there", "this", "that", "to", "my", "your", "hey", "please",
        "swiftbot", "bot", "know", "who", "where", "when", "why", "has", "have"
    ]

    /// The thing a question is about, with the question words taken out, or
    /// nil when the message isn't a question or names too much to be one item.
    static func wikiQuestionSubject(in prompt: String) -> String? {
        let cleaned = prompt
            .replacingOccurrences(of: #"<[@#][!&]?\d+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        let words = cleaned.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
            .filter { !$0.isEmpty }
        guard cleaned.contains("?") || words.contains(where: questionWords.contains) else { return nil }
        let subject = words.filter { !fillerWords.contains($0) }
        guard (1...4).contains(subject.count) else { return nil }
        return subject.joined(separator: " ")
    }
}
