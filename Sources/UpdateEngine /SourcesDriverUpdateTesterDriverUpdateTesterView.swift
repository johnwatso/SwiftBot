import SwiftUI

struct DriverUpdateTesterView: View {
    @State private var webhookURL: String = "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN"
    @State private var embedJSON: String = ""
    @State private var statusMessage: String = ""
    @State private var isLoading: Bool = false
    @State private var currentPayload: [String: Any]?
    
    private let discordService = DiscordWebhookService()
    private let nvidiaService = NVIDIAService()
    private let amdService = AMDService()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Driver Update Tester")
                .font(.title)
                .padding(.top)
            
            // Webhook URL Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Discord Webhook URL:")
                    .font(.headline)
                TextField("Webhook URL", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            
            // Fetch Buttons
            HStack(spacing: 16) {
                Button("Fetch Latest NVIDIA Driver") {
                    Task {
                        await fetchNVIDIADriver()
                    }
                }
                .disabled(isLoading)
                
                Button("Fetch Latest AMD Driver") {
                    Task {
                        await fetchAMDDriver()
                    }
                }
                .disabled(isLoading)
            }
            
            // Loading Indicator
            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }
            
            // Status Message
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                    .padding(.horizontal)
            }
            
            // Embed JSON Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Discord Embed JSON:")
                    .font(.headline)
                
                ScrollView {
                    Text(embedJSON)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                }
                .frame(height: 300)
            }
            .padding(.horizontal)
            
            // Send to Discord Button
            Button("Send to Discord") {
                Task {
                    await sendToDiscord()
                }
            }
            .disabled(currentPayload == nil || isLoading || webhookURL.isEmpty)
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .padding()
        .frame(width: 700, height: 650)
    }
    
    // MARK: - Fetch Functions
    
    private func fetchNVIDIADriver() async {
        isLoading = true
        statusMessage = "Fetching NVIDIA driver info..."
        
        do {
            let driverInfo = try await nvidiaService.fetchLatestDriver()
            let payload = discordService.buildDriverEmbed(
                vendor: "NVIDIA",
                driverInfo: driverInfo,
                roleMention: "@everyone"
            )
            
            currentPayload = payload
            embedJSON = prettyPrintJSON(payload)
            statusMessage = "✓ Successfully fetched NVIDIA driver info"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            embedJSON = ""
            currentPayload = nil
        }
        
        isLoading = false
    }
    
    private func fetchAMDDriver() async {
        isLoading = true
        statusMessage = "Fetching AMD driver info..."
        
        do {
            let driverInfo = try await amdService.fetchLatestDriver()
            let payload = discordService.buildDriverEmbed(
                vendor: "AMD",
                driverInfo: driverInfo,
                roleMention: "@everyone"
            )
            
            currentPayload = payload
            embedJSON = prettyPrintJSON(payload)
            statusMessage = "✓ Successfully fetched AMD driver info"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            embedJSON = ""
            currentPayload = nil
        }
        
        isLoading = false
    }
    
    private func sendToDiscord() async {
        guard let payload = currentPayload else { return }
        
        isLoading = true
        statusMessage = "Sending to Discord..."
        
        do {
            try await discordService.sendWebhook(payload: payload, webhookURL: webhookURL)
            statusMessage = "✓ Successfully sent to Discord!"
        } catch {
            statusMessage = "Error sending to Discord: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    // MARK: - Helper Functions
    
    private func prettyPrintJSON(_ dictionary: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "Error: Could not serialize JSON"
        }
        return jsonString
    }
}

#Preview {
    DriverUpdateTesterView()
}
