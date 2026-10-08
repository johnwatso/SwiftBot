# Combined recording libraries through Ruru

Someone signed into John's SwiftBot website can browse recordings stored on
both John's and Max's Macs and play Max's clip in the same player. Each Mac
owns its folders and media server. Max's bot can remain on Fail Over while his
Web Interface serves recordings. Browsing does not acquire the Discord lease.
Its browser homepage shows a small standby status page; viewers use the active
Primary's website for the combined library. When Max becomes Primary, his normal
WebUI returns automatically. Media serving does not depend on that browser page.

Ruru coordinates **where libraries are**. No recording lists, video, audio,
thumbnails, local file paths, Discord credentials or playback grants pass through
Ruru. Video playback currently follows Max's SwiftBot → John's SwiftBot → viewer.
John's SwiftBot proxies authenticated byte-range requests, so the viewer keeps
John's existing login and access checks. This uses John's network bandwidth.

## Setup on each Mac

1. Connect the Primary to a Ruru service through the existing SwiftMesh Ruru
   settings. On **the Mac being added**, sign into the Primary’s Web Interface
   and open **SwiftMesh → Pair SwiftBot**. Pairing requires a recent Discord
   admin sign-in over HTTPS, as before.
2. Choose **Share this Mac’s recordings** in that WebUI dialog and click
   **Continue in SwiftBot**. Its choice arrives preselected in the native Join
   confirmation, or first-launch Paired screen. Review and confirm joining on
   that Mac. The connection and shared secret are carried automatically; no
   separate Ruru setup is needed there. Sharing is a local opt-in and defaults
   off. **Copy Join Code** under **SwiftBot didn’t open?** keeps the same choice
   and remains a fallback.
3. Configure each Mac's **own** HTTPS Web Interface address through Internet
   Access and add its local recording folders in native Recordings. The address
   must already reach that Mac. Sharing sends that configured address; it does
   not copy the Primary's address, provision tunnels or change DNS.
4. SwiftBot automatically requests approval for that website through the inherited
   Ruru connection. Open that service in Ruru **Coordination → Website requests**,
   review the exact origin (for example `https://max.swiftbot.app`), and click
   **Approve**, or **Enable & Approve** if the catalogue is off. Repeat for John's
   website. Approval preserves other allowed origins and the service connection.
5. On an already-paired Mac, enable **Combine recording libraries through Ruru**
   under native **Recordings → Shared Library** and click **Save** to use the same
   request flow. A Primary's settings sync or an older generic settings save
   cannot turn sharing on or off for another Mac.
6. Sign into the active Primary's website and open Recordings. Local and shared
   recordings appear together in the existing Games/Recent views and source
   filter. SwiftBot reports after approval on its next regular directory refresh;
   no re-pairing is required.

If a paired Mac has no configured Ruru connection or HTTPS website yet, its local
sharing choice is retained and Recordings explains what to configure. An older
Ruru without origin enrollment still works: enable **Coordination → Resource
catalogue → Settings…** and manually add each exact HTTPS origin. No second Ruru
service, recording token or separate recordings app is needed.

Pending requests expire after ten minutes and can be resubmitted by the regular
refresh. Rejection appears in SwiftBot and suppresses that proposal until its
initial expiry; review the website in Ruru or retry sharing after expiry.
Disabling sharing withdraws pending requests as well as reported libraries.
Approved origins remain operator policy until removed in Ruru.

A node without an allowed HTTPS origin can browse other libraries, but does not
publish its own. The Web Interface must stay enabled and the SwiftBot app must
remain running. Stopping the Discord bot/failover watch does not stop sharing.
Quitting the app or disabling its Web Interface does stop serving. Turning
sharing off withdraws its Ruru location and revokes media admission immediately;
if Ruru is unreachable, its observation ages out normally.

Standby homepage selection uses the same runtime access guard as browser writes,
not the saved Primary/Fail Over role. It applies to anonymous visitors, admins and
members at `/` and `/index.html`, including bookmarks and HEAD probes. A small
same-origin `/live` JSON probe checks every ten seconds while the page is visible
and refreshes it across takeover or loss of ownership. It adds only the runtime
access flag to the existing public liveness response; no addresses or credentials.
The HTTP listener, mesh authentication, recording read allowlist, sessions and
server-side mutation guards remain independent of that page selection.

## Integration contract

SwiftBot uses Ruru's generic `resource-catalogue.v1` for library discovery.
When capabilities advertise `enrollmentSupported: true`, it also posts a v1
`/v1/coordination/enrollment` request with the paired cluster/node ID, reported
node name, own exact HTTPS origin and `withdraw: false`. The service bearer stays
in Keychain-backed configuration. Requests grant no access: only saved, enabled
allowed origins returned by capabilities permit reporting and peer routing.
Web pairing appends `recordings=1` or `recordings=0` to the existing
`swiftmesh://join?b=…` link. This is a local UI preference, not a permission grant
or service policy. Both native entry paths read it, then persist only after local
confirmation. Missing, invalid or repeated values leave the existing local choice
as the default. The bundle and legacy lease protocol remain unchanged; older
SwiftBot builds ignore this hint and need the choice set locally after updating.
Library reports use:

| Field | Value |
| --- | --- |
| Namespace | `swiftbot.recording-library.v1` |
| Resource ID | `library` |
| Node ID | That Mac's stable enrollment ID, also used for Ruru lease identity |
| Title | `SwiftBot recording library` |
| URL | The Mac's allowed HTTPS origin plus `/v1/media/library` |

Each Mac reports **one library location**, independent of file count. Reports
repeat every 25–35 seconds through a separate client/session, and do not delay
lease renewals. Ruru reports age monotonically; locations are fresh for 90 seconds
and its process restart starts empty. SwiftBot re-reports and reads all catalogue
pages with revision checks, bounded restarts and a 15-second traversal budget.
Ruru's existing 16-node/service and eight-origin/service limits apply.

SwiftBot retrieves rich recording metadata directly from the reported hosts.
The peer library response retains the existing media wire format and adds optional
`nodeID`, `unavailableSourceIDs` and `fresh` fields. Local file identifiers remain
`source UUID|relative path`. Browser item/source keys use the stable node ID;
display names no longer decide whether a shared clip is local. Moving a file
still changes its local ID; intentional replicas and cross-node session matching
are future work.

The Web Interface forwards only these authenticated media reads to the media
handlers: `/v1/media/library`, `/v1/media/playback`, `/v1/media/stream`,
`/v1/media/thumbnail` and `/v1/media/frame`. The separate mesh-port routes enforce
the same opt-in. All require a nonempty mesh secret and valid HMAC, regardless of
bot role. Recording sharing does not authorize remote exports or mutations.

Playback descriptors carry stable node/item IDs. Their optional legacy URL field
cannot select the authenticated destination. Each request resolves its owner
against fresh, service-scoped Ruru observations and exact allowed origins.
Recording network sessions reject redirects and never retry HTTPS over HTTP.
Legacy local links continue to work; old remote links need a library refresh.
The service token trusts the entire group: node IDs are reported identity, not
independently authenticated Ruru principals.

WebUI sessions continue to authorize viewers. Members retain the existing rule
that they can play only clips they appear in, including when authenticating with
a media access token. Mesh secrets and Ruru tokens remain server-side in their
existing Keychain-backed configuration; neither appears in browser URLs.

## Outages and bounds

Local unavailable folders retain previously indexed files with unavailable source
markers. Remote lists revalidate every 30 seconds and retain metadata for five
minutes on a transport outage, using monotonic cache age. Recently known libraries
whose Ruru location disappears can remain visible as unavailable for up to ten
minutes. These states disable starting playback; retained lists never provide
missing bytes. Fresh reports are observations, not independent reachability proof.

The Ruru directory client admits at most 16 matching libraries after validating
service, namespace, origin, endpoint path and age. Peer metadata/responses are
limited to 8 MiB, playback-choice replies to 4 KiB, and video responses use the
existing 8 MiB range chunks. Shared MP4 playback pins its chosen original/copy;
remote HLS, direct browser-to-owner playback, replication, durable media catalogues
and cross-node editing are not implemented. Full peer-list paging beyond the
metadata response bound is future work.

Runtime implementation is in `RecordingDirectoryClient.swift` and
`AppModel+RecordingCoordination.swift`; local indexing/encoding stays in
`RecordingsKit`. No Ruru build dependency or application-specific Ruru authority
code is required.

## Validation

The Debug Xcode build and 101 focused tests passed, including 12 coordination
scenarios and three recording reliability tests. Pairing imports synthetic Ruru
credentials into isolated stores, retains the Fail Over's own website, installs
its new stable node ID and sends a pending proposal. Approval then enables
reporting without a lease request. Persistence tests prevent stale generic
settings saves from undoing or reviving explicit sharing choices. Tests combine
201 clips with colliding display names, play a ranged response through the real public/mesh routers while the owner is Standby, and
reject unknown or expired destinations. They cover revocation, transport outage,
Ruru restart, page conflicts, withdrawals, member media-token permissions and
real loopback redirects for both clients. Folder availability and legacy decoding
are also checked. Fixtures use isolated storage and synthetic credentials.

The WebUI pairing dialog, sharing handoff/copy fallback and native confirmation,
paired state and first-launch screen have been checked in isolated previews.
The deployed John/Max servers have not been exercised. Both Macs need the updated SwiftBot build and setup above before a
live playback test. No release or network configuration was changed.
