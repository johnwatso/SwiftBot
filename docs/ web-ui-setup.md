# SwiftBot Web UI & HTTPS Setup

SwiftBot includes a built-in **Admin Web UI** that allows server administrators to manage the bot through a browser.

The Web UI supports:

- Local access for development
- Discord authentication for administrators
- Optional HTTPS using **Let's Encrypt**
- Automatic DNS validation via **Cloudflare**
- Optional **manual certificate import**

This guide explains how to configure the dashboard.

---

# 1. Enabling the Web UI

Open **SwiftBot Settings → Web UI** and enable:

Enable Admin Web UI

Recommended settings:

Bind Address: 127.0.0.1  
Port: 38888

Once enabled, open your browser:

http://127.0.0.1:38888

---

# 2. Discord Authentication

The Web UI uses Discord authentication to ensure only administrators can access the dashboard.

## Create a Discord Application

1. Go to:
https://discord.com/developers/applications

2. Click **New Application**

3. Open **OAuth2 → General**

4. Copy the following values:

Client ID  
Client Secret

5. Paste them into **SwiftBot → Authentication**

---

## OAuth Redirect URL

Add the redirect URL to the Discord application:

http://127.0.0.1:38888/auth/discord/callback

If using HTTPS:

https://admin.example.com/auth/discord/callback

---

# 3. Enabling HTTPS (Recommended)

SwiftBot can automatically provision TLS certificates using **Let's Encrypt**.

Requirements:

- A domain name
- DNS hosted on Cloudflare
- A Cloudflare API token

Enable:

Enable HTTPS  
Certificate Mode: Automatic (Let's Encrypt)

---

# 4. Creating a Cloudflare API Token

SwiftBot uses the Cloudflare API for DNS validation and (optionally) Cloudflare Tunnel. The **same token** is used for both HTTPS and Public Access.

1. Log into Cloudflare

2. Navigate to:

My Profile → API Tokens

3. Click **Create Token**

4. Use **Custom Token** with these permissions:

| Permission | Level | Purpose |
|------------|-------|---------|
| Zone → DNS → Edit | Zone | Create DNS records for validation |
| Zone → Zone → Read | Zone | Look up zone information |
| Account → Cloudflare Tunnel → Edit | Account | Create/manage tunnels (Public Access) |
| Account → Account Settings → Read | Account | Read account ID |

5. Under **Zone Resources**, select:

Include → Specific Zone → (your domain)

6. Click **Continue to summary** then **Create Token**

7. Copy the token and paste it into:

SwiftBot → Settings → HTTPS → Cloudflare API Token

The token is automatically shared between HTTPS and Public Access sections.

---

# 5. DNS Configuration

Create a DNS record for your dashboard.

Example:

admin.example.com → YOUR.SERVER.IP

Example configuration:

Type: A  
Name: admin  
Content: YOUR.SERVER.IP

---

# 6. HTTPS Setup Validation

SwiftBot automatically validates the configuration before requesting a certificate.

The **HTTPS Status** section checks:

- Cloudflare API token validity
- Domain ownership
- DNS record presence
- DNS resolution

Example status:

✓ Cloudflare API token valid  
✓ Domain found  
✓ DNS record present  
✓ Ready for certificate request

If a problem is detected, SwiftBot will show guidance for fixing it.

---

# 7. Certificate Import (Optional)

Instead of using Let's Encrypt, you can import an existing certificate.

Select:

Certificate Mode → Import Certificate

Then provide:

Certificate (.pem)  
Private Key (.pem)  
Certificate Chain (.pem) (optional)

Certificates will be stored in:

~/Library/Application Support/SwiftBot/certs/

---

# 8. Accessing the Dashboard

After HTTPS is configured, open:

https://admin.example.com

Log in using your Discord account.

Only **server administrators** are allowed to access the dashboard by default.

---

# 9. Public Access (Cloudflare Tunnel)

SwiftBot can expose the Web UI to the internet without router port forwarding using **Cloudflare Tunnel**.

## Requirements

- HTTPS configured (above)
- Cloudflare API token with Tunnel permissions (see step 4)

## Setup

1. Go to **SwiftBot → Settings → Public Access**

2. Enable **Public Access**

3. Enter the same hostname used for HTTPS (e.g., `admin.example.com`)

4. Click **Enable Public Access**

SwiftBot will:
- Create a Cloudflare tunnel (or reuse an existing one)
- Configure DNS routing
- Start the tunnel automatically

## Using Existing Tunnels

If you previously created a tunnel with the same name, SwiftBot will automatically detect and reuse it. No manual cleanup needed.

Status indicators:
- **✓ Cloudflare tunnel detected** — Reusing existing tunnel
- **✓ Created tunnel** — New tunnel created

---

# 10. Troubleshooting

## Domain does not resolve

Check your DNS record:

admin.example.com → SERVER IP

---

## Cloudflare token invalid

Ensure the token has all required permissions:

**For HTTPS:**
- Zone → DNS → Edit
- Zone → Zone → Read

**For Public Access (additionally):**
- Account → Cloudflare Tunnel → Edit
- Account → Account Settings → Read

---

## Certificate request failed

Verify:

- Domain resolves correctly
- DNS record exists
- Cloudflare token has correct permissions

---

## "Cloudflare authentication required" error

The API token field is empty. Re-enter your token in:

SwiftBot → Settings → HTTPS → Cloudflare API Token

The token is shared between HTTPS and Public Access sections.

---

# 11. Security Notes

- SwiftBot stores Cloudflare tokens securely in the system keychain.
- Discord authentication ensures only administrators can access the dashboard.
- HTTPS certificates are automatically renewed before expiration.

---

# 12. Example Architecture

Browser  
↓  
HTTPS (Let's Encrypt)  
↓  
SwiftBot Web UI  
↓  
Discord Authentication  
↓  
Bot Administration

---

# 13. Next Steps

You can also configure:

- SwiftMesh cluster networking
- automatic updates
- plugin modules

See additional documentation in the `docs/` directory.