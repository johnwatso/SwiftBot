import SwiftUI

/// Shows the bundled third-party license notices.
///
/// The notices have to accompany every distributed copy of the app — Apache-2.0
/// and the BSD/MIT packages all require it — so `THIRD-PARTY-NOTICES.md` ships as
/// a bundle resource and is read from disk here rather than fetched.
struct AcknowledgementsView: View {
    @State private var contents: String?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let contents {
                ScrollView {
                    Text(contents)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else if loadFailed {
                ContentUnavailableView(
                    "Notices Unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("THIRD-PARTY-NOTICES.md is missing from the app bundle.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            guard contents == nil, !loadFailed else { return }
            guard let text = Self.loadNotices() else {
                loadFailed = true
                return
            }
            contents = text
        }
    }

    static func loadNotices() -> String? {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
