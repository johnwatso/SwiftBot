const searchIndex = [
  // Install
  {
    title: "Install SwiftBot on macOS",
    url: "install/",
    category: "Install",
    keywords: "install download release zip applications macos apple silicon requirements sparkle beta stable updates",
    snippet: "Download the signed release, move SwiftBot to Applications, and choose an update channel."
  },
  {
    title: "SwiftBot Requirements",
    url: "install/#requirements",
    category: "Install",
    keywords: "requirements macos 26 apple silicon discord bot token internet",
    snippet: "What you need before installing: macOS 26, Apple Silicon, and a Discord bot token."
  },
  {
    title: "Install Steps",
    url: "install/#install-steps",
    category: "Install",
    keywords: "install steps download zip unzip applications launch onboarding keychain token",
    snippet: "Step-by-step instructions to download, install, and launch SwiftBot."
  },
  {
    title: "Updates with Sparkle",
    url: "install/#updates",
    category: "Install",
    keywords: "updates sparkle in-app stable beta channel appcast",
    snippet: "SwiftBot uses Sparkle for in-app updates. Choose the stable or beta channel."
  },

  // Discord Bot Setup
  {
    title: "Create and Connect Your Discord Bot",
    url: "bot-setup/",
    category: "Discord Setup",
    keywords: "discord developer portal application bot token privileged gateway intents oauth redirect invite code grant",
    snippet: "Create the Discord application, copy the bot token, enable intents, and configure OAuth."
  },
  {
    title: "Create the Discord Application",
    url: "bot-setup/#create-app",
    category: "Discord Setup",
    keywords: "create application new discord developer portal name",
    snippet: "Open the Discord Developer Portal and create a new application for SwiftBot."
  },
  {
    title: "Add the Bot and Copy Its Token",
    url: "bot-setup/#bot-token",
    category: "Discord Setup",
    keywords: "bot token reset token copy keychain onboarding paste",
    snippet: "Add the bot, copy its token once, and paste it into SwiftBot onboarding."
  },
  {
    title: "Enable Gateway Intents",
    url: "bot-setup/#intents",
    category: "Discord Setup",
    keywords: "gateway intents server members message content presence privileged",
    snippet: "Enable Server Members, Message Content, and Presence intents in the portal."
  },
  {
    title: "Configure OAuth and Redirect URIs",
    url: "bot-setup/#oauth",
    category: "Discord Setup",
    keywords: "oauth client id client secret redirect uri callback web ui authentication",
    snippet: "Copy the Client ID and Secret and register the correct redirect URIs."
  },

  // Admin Web UI
  {
    title: "Admin Web UI Setup",
    url: "web-ui/",
    category: "Web UI",
    keywords: "web ui admin dashboard localhost cloudflare tunnel public access reverse proxy port forwarding override base url tls oauth",
    snippet: "Run the dashboard locally or publish it securely through Cloudflare Tunnel or a reverse proxy."
  },
  {
    title: "Web UI Access Modes",
    url: "web-ui/#access-modes",
    category: "Web UI",
    keywords: "access modes local only cloudflare tunnel reverse proxy port forwarding supported unsupported",
    snippet: "Compare local-only, Cloudflare Tunnel, reverse proxy, and why port forwarding is unsupported."
  },
  {
    title: "Local-Only Web UI Access",
    url: "web-ui/#local-access",
    category: "Web UI",
    keywords: "local access localhost port 8090 enable admin web ui",
    snippet: "Enable the Admin Web UI and reach it at localhost on the Mac running SwiftBot."
  },
  {
    title: "Cloudflare Tunnel Setup",
    url: "web-ui/#cloudflare-tunnel",
    category: "Web UI",
    keywords: "cloudflare tunnel api token subdomain dns zone internet access https oauth redirect",
    snippet: "Publish the Web UI over HTTPS with a scoped Cloudflare API token and subdomain."
  },
  {
    title: "Custom Reverse Proxy",
    url: "web-ui/#reverse-proxy",
    category: "Web UI",
    keywords: "reverse proxy nginx caddy tls override public base url localhost 8090",
    snippet: "Forward your own proxy to SwiftBot and set the Override Public Base URL."
  },

  // SwiftMesh
  {
    title: "Set Up Failover with SwiftMesh",
    url: "swiftmesh/",
    category: "SwiftMesh",
    keywords: "swiftmesh failover primary standby worker join code shared secret handover cluster live endpoint port forwarding",
    snippet: "Pair a standby Mac that mirrors the primary node and promotes itself during an outage."
  },
  {
    title: "SwiftMesh Roles",
    url: "swiftmesh/#roles",
    category: "SwiftMesh",
    keywords: "roles standalone primary fail over worker node gateway",
    snippet: "Understand the Standalone, Primary, Fail Over, and Worker roles."
  },
  {
    title: "SwiftMesh Network Rule",
    url: "swiftmesh/#network",
    category: "SwiftMesh",
    keywords: "network port 38787 tcp lan wan port forwarding outbound mesh",
    snippet: "How standby nodes connect to the primary's mesh port and when forwarding is needed."
  },
  {
    title: "Pair with a Join Code",
    url: "swiftmesh/#join-code",
    category: "SwiftMesh",
    keywords: "join code pair primary standby onboarding sync lan wan address",
    snippet: "Copy the Join Code on the Primary and paste it into the Standby to begin syncing."
  },
  {
    title: "SwiftMesh Security and Recovery",
    url: "swiftmesh/#security-recovery",
    category: "SwiftMesh",
    keywords: "security recovery join code bearer rotate shared secret handover test live endpoint probe",
    snippet: "Treat Join Codes as credentials, rotate the secret, and rehearse handovers."
  },

  // Troubleshooting
  {
    title: "Quick Troubleshooting",
    url: "troubleshooting/",
    category: "Troubleshooting",
    keywords: "troubleshooting fix invalid redirect uri unauthorized disallowed intents cloudflare 502 code grant standby pairing cgnat",
    snippet: "Fixes for redirect mismatches, missing intents, tunnel errors, and pairing failures."
  },
  {
    title: "Invalid OAuth2 redirect_uri",
    url: "troubleshooting/#redirect-uri",
    category: "Troubleshooting",
    keywords: "invalid redirect uri oauth2 callback scheme host port path trailing slash",
    snippet: "Match the exact redirect URI from SwiftBot in Discord's OAuth2 redirects."
  },
  {
    title: "Integration Requires Code Grant",
    url: "troubleshooting/#code-grant",
    category: "Troubleshooting",
    keywords: "requires oauth2 code grant invite url disallowed turn off",
    snippet: "Turn off Requires OAuth2 Code Grant unless you have configured OAuth first."
  },
  {
    title: "Bot Cannot See Members or Messages",
    url: "troubleshooting/#intents",
    category: "Troubleshooting",
    keywords: "intents server members message content cannot see members messages restart",
    snippet: "Enable the privileged gateway intents and restart SwiftBot."
  },
  {
    title: "Cloudflare 502 Bad Gateway",
    url: "troubleshooting/#cloudflare-502",
    category: "Troubleshooting",
    keywords: "cloudflare 502 bad gateway tunnel local port web ui enabled stale restart",
    snippet: "Confirm the Web UI is enabled and the tunnel port matches, then restart."
  },
  {
    title: "Standby Cannot Pair Across the Internet",
    url: "troubleshooting/#standby-pairing",
    category: "Troubleshooting",
    keywords: "standby pair internet mesh port forward firewall cgnat isp",
    snippet: "Check mesh port forwarding, macOS firewall, and possible CGNAT on the ISP."
  },

  // Security & Privacy
  {
    title: "Security & Privacy",
    url: "security-privacy/",
    category: "Security & Privacy",
    keywords: "security privacy keychain tokens local app state no hosted account cloud remote access oauth tunnel",
    snippet: "How SwiftBot keeps secrets in Keychain, stays local, and requires no hosted account."
  },
  {
    title: "Secrets Stay in Keychain",
    url: "security-privacy/#keychain",
    category: "Security & Privacy",
    keywords: "keychain bot token api keys secrets encryption plain text config",
    snippet: "Bot tokens and API keys are stored in the macOS Keychain, not plain text files."
  },
  {
    title: "Local App State",
    url: "security-privacy/#local-state",
    category: "Security & Privacy",
    keywords: "local app state settings rules logs cached discord metadata mac",
    snippet: "Settings, rules, logs, and cached Discord metadata live on the Mac running SwiftBot."
  },
  {
    title: "No Required Hosted Account",
    url: "security-privacy/#remote-access",
    category: "Security & Privacy",
    keywords: "no hosted account cloud remote access optional web ui oauth tunnel controlled",
    snippet: "Remote access is optional and controlled by your own Web UI, OAuth, and tunnel settings."
  }
];
