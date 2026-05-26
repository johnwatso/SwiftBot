// MARK: - Archived Unused Auth Providers (Apple / Steam / GitHub)
// Preserved here in case we ever want to bring these sign-in methods back.
//
// Original files touched:
// - WebUIPreferencesView.swift
// - Models/BotSettings.swift

import SwiftUI

// MARK: - BotSettings properties in AdminWebUISettings
/*
var appleOAuth = OAuthProviderSettings()
var steamOAuth = OAuthProviderSettings()
var githubOAuth = OAuthProviderSettings()
*/

// MARK: - Original View Cards in WebUIPreferencesView.swift
/*
struct ArchivedWebUIAuthProvidersView: View {
    @EnvironmentObject var app: AppModel

    private func redirectURL(for provider: String) -> String {
        app.adminWebDiscordRedirectURL() // fallback or custom url resolution
    }

    var body: some View {
        VStack(spacing: 12) {
            OAuthProviderCard(
                name: "Apple",
                icon: "apple.logo",
                color: .primary,
                settings: $app.settings.adminWebUI.appleOAuth,
                redirectURL: redirectURL(for: "apple")
            )

            OAuthProviderCard(
                name: "Steam",
                icon: "gamecontroller.fill",
                color: .blue,
                settings: $app.settings.adminWebUI.steamOAuth,
                redirectURL: redirectURL(for: "steam")
            )

            OAuthProviderCard(
                name: "GitHub",
                icon: "cat.fill",
                color: .primary,
                settings: $app.settings.adminWebUI.githubOAuth,
                redirectURL: redirectURL(for: "github")
            )
        }
    }
}
*/
