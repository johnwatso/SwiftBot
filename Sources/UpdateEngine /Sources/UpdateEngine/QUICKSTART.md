# SwiftBot Quick Start Guide

## Setup in 5 Minutes

### 1. Configure Guilds

Create `config/guilds.json`:

```json
{
  "guilds": [
    {
      "guild_id": "YOUR_GUILD_ID_HERE",
      "webhook_url": "https://discord.com/api/webhooks/YOUR_WEBHOOK_ID/YOUR_WEBHOOK_TOKEN",
      "enabled_vendors": ["NVIDIA", "AMD"]
    }
  ]
}
```

**How to get these values**:

1. **Guild ID**: 
   - Enable Developer Mode in Discord (Settings → Advanced)
   - Right-click your server → Copy ID

2. **Webhook URL**:
   - Go to Server Settings → Integrations → Webhooks
   - Create New Webhook
   - Choose channel for driver updates
   - Copy Webhook URL

### 2. Run the Bot

```bash
# Build
swift build

# Run
swift run
```

You'll see:
```
=== Driver Update SwiftBot ===
Initializing...
Loaded 1 guild(s) from configuration
Version store: ./data/versions.json

✓ Starting update polling...
✓ Checking every 60 minutes
✓ Monitoring 1 guild(s)

Bot is running. Press Ctrl+C to stop.
```

### 3. Test It

Wait for the first polling cycle (or manually trigger by restarting).

You should see logs like:
```
[GuildUpdateService] Checking 1 guilds for updates...
[GuildUpdateService] Fetched NVIDIA v560.81
[GuildUpdateService] Fetched AMD v24.3.1
[GuildUpdateService] Guild YOUR_GUILD_ID - NVIDIA: First check (v560.81)
[GuildUpdateService] Guild YOUR_GUILD_ID - AMD: First check (v24.3.1)
```

**Note**: First check saves versions but doesn't send notifications. This prevents spam when adding guilds.

### 4. Wait for an Update

When a new driver is released, you'll see:
```
[GuildUpdateService] Guild YOUR_GUILD_ID - NVIDIA: Version changed 560.81 → 560.94
[GuildUpdateService] Successfully sent NVIDIA update to guild YOUR_GUILD_ID
```

And your Discord channel will receive the embed!

## Multiple Guilds

Add more guilds to `guilds.json`:

```json
{
  "guilds": [
    {
      "guild_id": "123456789012345678",
      "webhook_url": "https://discord.com/api/webhooks/...",
      "enabled_vendors": ["NVIDIA", "AMD"]
    },
    {
      "guild_id": "987654321098765432",
      "webhook_url": "https://discord.com/api/webhooks/...",
      "enabled_vendors": ["NVIDIA"]
    },
    {
      "guild_id": "555555555555555555",
      "webhook_url": "https://discord.com/api/webhooks/...",
      "enabled_vendors": ["AMD", "Intel"]
    }
  ]
}
```

Each guild:
- Tracks versions independently
- Receives updates only for enabled vendors
- Uses its own webhook URL

## Configuration Options

### Environment Variables

```bash
# Custom config location
export GUILDS_CONFIG_PATH=/etc/driver-bot/guilds.json

# Custom version store location
export VERSION_STORE_PATH=/var/lib/driver-bot/versions.json

swift run
```

### Vendor Options

Available vendors:
- `"NVIDIA"` - GeForce Game Ready Drivers
- `"AMD"` - Radeon Adrenalin Drivers
- `"Intel"` - Intel Arc Drivers (when implemented)

## Docker Deployment

### Dockerfile

Already included in the project.

### Run with Docker

```bash
# Build
docker build -t driver-bot .

# Run
docker run -d \
  -v $(pwd)/config:/app/config \
  -v $(pwd)/data:/app/data \
  --name driver-bot \
  driver-bot
```

### Docker Compose

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  driver-bot:
    build: .
    volumes:
      - ./config:/app/config
      - ./data:/app/data
    restart: unless-stopped
```

Run:
```bash
docker-compose up -d
```

## Troubleshooting

### "No guilds configured!"

- Check `config/guilds.json` exists
- Verify JSON syntax is correct
- Ensure file is readable

### Webhook not working

- Verify webhook URL is correct
- Check webhook channel permissions
- Test webhook manually with curl:

```bash
curl -X POST "YOUR_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"content": "Test message"}'
```

### Not receiving updates

- Wait for a driver release (or test with version cache reset)
- Check logs for errors
- Verify vendor is enabled for guild
- Check `data/versions.json` for cached versions

### Reset version cache

To force notifications on next cycle:

```bash
# Backup first
cp data/versions.json data/versions.json.backup

# Clear cache
rm data/versions.json

# Restart bot
```

## Production Deployment

### Systemd Service

See `POLLING_SYSTEM.md` for complete systemd configuration.

### Monitoring

Add logging to a file:

```bash
swift run 2>&1 | tee -a /var/log/driver-bot.log
```

### Automatic Restart

Use systemd with `Restart=always` or Docker with `restart: unless-stopped`.

## Support

For detailed documentation, see:
- `POLLING_SYSTEM.md` - Complete polling system docs
- `PER_GUILD_ARCHITECTURE.md` - Architecture details
- `VERSION_CACHING_README.md` - Version caching system

## Example: Complete Setup

```bash
# 1. Clone/download project
cd DriverUpdateTester

# 2. Create config directory
mkdir -p config

# 3. Create guilds.json
cat > config/guilds.json << 'EOF'
{
  "guilds": [
    {
      "guild_id": "123456789012345678",
      "webhook_url": "https://discord.com/api/webhooks/YOUR_WEBHOOK",
      "enabled_vendors": ["NVIDIA", "AMD"]
    }
  ]
}
EOF

# 4. Build and run
swift build
swift run
```

That's it! Your bot is now running and will check for updates every 60 minutes.
