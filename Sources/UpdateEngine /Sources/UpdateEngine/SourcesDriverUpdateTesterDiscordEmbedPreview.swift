import SwiftUI

// MARK: - Discord Embed Models

struct DiscordEmbed: Decodable {
    let embeds: [Embed]
    
    struct Embed: Decodable {
        let author: Author?
        let title: String?
        let url: String?
        let description: String?
        let color: Int?
        let thumbnail: Thumbnail?
        let fields: [Field]?
        
        struct Author: Decodable {
            let name: String
            let url: String?
            let iconURL: String?
            
            enum CodingKeys: String, CodingKey {
                case name
                case url
                case iconURL = "icon_url"
            }
        }
        
        struct Thumbnail: Decodable {
            let url: String
        }
        
        struct Field: Decodable {
            let name: String
            let value: String
            let inline: Bool?
        }
    }
}

// MARK: - Discord Embed Preview View (Debug Tool)

struct DiscordEmbedPreview: View {
    let embedJSON: String
    
    @State private var parsedEmbed: DiscordEmbed.Embed?
    @State private var parseError: String?
    @State private var selectedMode: PreviewMode = .preview
    
    enum PreviewMode: String, CaseIterable {
        case preview = "Preview"
        case rawJSON = "Raw JSON"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Discord Embed Inspector")
                    .font(.headline)
                
                Spacer()
                
                Picker("Mode", selection: $selectedMode) {
                    ForEach(PreviewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            
            Divider()
            
            // Content
            if let error = parseError {
                Text("Parse Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            } else if let embed = parsedEmbed {
                switch selectedMode {
                case .preview:
                    previewSection(embed: embed)
                case .rawJSON:
                    rawJSONSection()
                }
                
                Divider()
                
                // Discord Limits Diagnostics
                limitsSection(embed: embed)
                
                Divider()
                
                // Debug Information
                debugSection(embed: embed)
            } else {
                Text("No embed to preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .onChange(of: embedJSON) { _, newValue in
            parseEmbed(newValue)
        }
        .onAppear {
            parseEmbed(embedJSON)
        }
    }
    
    // MARK: - Preview Section
    
    @ViewBuilder
    private func previewSection(embed: DiscordEmbed.Embed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visual Preview")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            DiscordEmbedCard(embed: embed)
        }
    }
    
    // MARK: - Raw JSON Section
    
    @ViewBuilder
    private func rawJSONSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Formatted JSON")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            ScrollView {
                Text(embedJSON)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(height: 200)
        }
    }
    
    // MARK: - Limits Section
    
    @ViewBuilder
    private func limitsSection(embed: DiscordEmbed.Embed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discord Character Limits")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 4) {
                limitRow(
                    label: "Title",
                    count: embed.title?.count ?? 0,
                    limit: 256
                )
                
                limitRow(
                    label: "Description",
                    count: embed.description?.count ?? 0,
                    limit: 4096
                )
                
                if let fields = embed.fields {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        limitRow(
                            label: "Field \(index + 1) Value",
                            count: field.value.count,
                            limit: 1024
                        )
                    }
                }
                
                let totalSize = estimateTotalSize(embed: embed)
                limitRow(
                    label: "Total Embed Size",
                    count: totalSize,
                    limit: 6000,
                    isTotal: true
                )
            }
            .font(.caption)
            
            if hasLimitViolations(embed: embed) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Warning: One or more Discord limits exceeded!")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(.top, 4)
            }
        }
    }
    
    @ViewBuilder
    private func limitRow(label: String, count: Int, limit: Int, isTotal: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text("\(count) / \(limit)")
                .foregroundStyle(count > limit ? .red : .primary)
                .fontWeight(count > limit ? .semibold : .regular)
            
            if count > limit {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(isTotal ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
    
    // MARK: - Debug Section
    
    @ViewBuilder
    private func debugSection(embed: DiscordEmbed.Embed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug Information")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 4) {
                debugRow(label: "Has Author", value: embed.author != nil)
                debugRow(label: "Has Title", value: embed.title != nil)
                debugRow(label: "Has Description", value: embed.description != nil)
                debugRow(label: "Has Color", value: embed.color != nil)
                debugRow(label: "Has Thumbnail", value: embed.thumbnail != nil)
                debugRow(label: "Field Count", value: "\(embed.fields?.count ?? 0)")
                
                if let thumbnail = embed.thumbnail {
                    debugRow(
                        label: "Thumbnail URL Valid",
                        value: URL(string: thumbnail.url) != nil
                    )
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
        }
    }
    
    @ViewBuilder
    private func debugRow(label: String, value: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(value ? .green : .orange)
        }
    }
    
    @ViewBuilder
    private func debugRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
    
    // MARK: - Helper Functions
    
    private func parseEmbed(_ json: String) {
        guard !json.isEmpty else {
            parsedEmbed = nil
            parseError = nil
            return
        }
        
        guard let data = json.data(using: .utf8) else {
            parseError = "Invalid JSON string"
            parsedEmbed = nil
            return
        }
        
        do {
            let decoded = try JSONDecoder().decode(DiscordEmbed.self, from: data)
            parsedEmbed = decoded.embeds.first
            parseError = nil
        } catch {
            parseError = error.localizedDescription
            parsedEmbed = nil
        }
    }
    
    private func estimateTotalSize(embed: DiscordEmbed.Embed) -> Int {
        var total = 0
        total += embed.title?.count ?? 0
        total += embed.description?.count ?? 0
        total += embed.author?.name.count ?? 0
        
        if let fields = embed.fields {
            for field in fields {
                total += field.name.count
                total += field.value.count
            }
        }
        
        return total
    }
    
    private func hasLimitViolations(embed: DiscordEmbed.Embed) -> Bool {
        if (embed.title?.count ?? 0) > 256 { return true }
        if (embed.description?.count ?? 0) > 4096 { return true }
        
        if let fields = embed.fields {
            for field in fields {
                if field.value.count > 1024 { return true }
            }
        }
        
        if estimateTotalSize(embed: embed) > 6000 { return true }
        
        return false
    }
}

// MARK: - Simple Discord Embed Card (Debug View)

struct DiscordEmbedCard: View {
    let embed: DiscordEmbed.Embed
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left colored accent bar
            Rectangle()
                .fill(embedColor)
                .frame(width: 4)
            
            // Main embed content
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    // Author
                    if let author = embed.author {
                        Text(author.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Title
                    if let title = embed.title {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    
                    // Description (with Markdown rendering for links)
                    if let description = embed.description {
                        formattedDescription(description)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Fields
                    if let fields = embed.fields, !fields.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.name)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                    Text(field.value)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Thumbnail (rendered image, not text)
                if let thumbnail = embed.thumbnail, let url = URL(string: thumbnail.url) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .cornerRadius(6)
                        case .failure, .empty:
                            // No placeholder - render nothing if image fails
                            EmptyView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func formattedDescription(_ description: String) -> some View {
        // Use AttributedString with markdown to support clickable links
        // This preserves bold, links, and other Markdown formatting
        if let attributedString = try? AttributedString(markdown: description, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributedString)
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
        } else {
            // Fallback to manual line-by-line parsing
            let lines = description.components(separatedBy: "\n")
            
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    formattedLine(line)
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
        }
    }
    
    @ViewBuilder
    private func formattedLine(_ line: String) -> some View {
        // Check if line is a bold heading (e.g., "**Highlights**")
        if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
            let headingText = String(line.dropFirst(2).dropLast(2))
            Text(headingText)
                .font(.body)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
        } else {
            // Preserve original formatting with spaces/bullets
            Text(line)
        }
    }
    
    private var embedColor: Color {
        guard let colorInt = embed.color else {
            return Color.secondary
        }
        
        let red = Double((colorInt >> 16) & 0xFF) / 255.0
        let green = Double((colorInt >> 8) & 0xFF) / 255.0
        let blue = Double(colorInt & 0xFF) / 255.0
        
        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - Preview

#Preview {
    let sampleJSON = """
    {
      "embeds": [
        {
          "author": {
            "name": "AMD Radeon Drivers"
          },
          "title": "AMD Software: Adrenalin Edition 24.3.1 Release Notes",
          "url": "https://www.amd.com/en-us/support",
          "description": "**Highlights**\\n• Support for new AAA game titles\\n   ◦ Game optimization improvements\\n   ◦ Enhanced ray tracing performance\\n• Driver stability improvements\\n\\n**Fixed Issues**\\n• Resolved crash in specific scenarios\\n• Fixed visual artifacts in certain games\\n\\n[Download Driver](https://www.amd.com/download)",
          "color": 16711680,
          "thumbnail": {
            "url": "https://upload.wikimedia.org/wikipedia/commons/7/7c/AMD_Logo.svg"
          },
          "fields": [
            {
              "name": "Release Date",
              "value": "March 3, 2026",
              "inline": true
            }
          ]
        }
      ]
    }
    """
    
    return DiscordEmbedPreview(embedJSON: sampleJSON)
        .padding()
        .frame(width: 700)
}
