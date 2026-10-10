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
`/v1/media/thumbnail`, `/v1/media/frame`, `/v1/media/hls` and `/v1/media/hls-segment`. The separate mesh-port routes enforce
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
existing 8 MiB range chunks. HLS playlists are limited to 1 MiB and segments to
8 MiB. Shared MP4 playback pins its chosen original/copy. Shared HLS is encoded
on the Mac holding the recording and relayed through the viewer's SwiftBot server;
peer manifests carry bare names, and only the viewer's server attaches its media
access token. Every playlist and chunk retains the existing member/sharing guards.
Rendition URLs include a source revision digest so replaced files cannot mix chunks.
Direct browser-to-owner playback, replication, durable media catalogues and
cross-node editing are not implemented. Full peer-list paging beyond the
metadata response bound is future work.

## Progressive recording playback

Current owners select HLS through `/v1/media/playback`; older owners can still
select their cached MP4 or original. AVFoundation and required VideoToolbox
hardware encoding publish H.264/AAC fMP4 chunks directly, without exporting a
complete MP4 first. The master advertises 720p/3 Mbps and 1080p/8 Mbps ceilings;
small sources are not upscaled, and source frame cadence is retained. The WebUI
uses native HLS when available, otherwise the already bundled hls.js player,
starting with the low rendition and adapting to available bandwidth.

Rendition playlists grow as EVENT streams. Cached seeks use the current HLS
range immediately. An uncached seek requests a `seek-<seconds>-master.m3u8`
namespace through the existing authenticated HLS segment route. The owner uses
AVAssetReader.timeRange to start within two seconds before the requested point,
rebases video and audio sample timing together, and hardware-encodes HLS from
there. The browser applies the remaining offset and retains the full recording
timeline, current play/pause intent and selected adaptive rendition. The master
returns the duration measured by AVFoundation, including through the peer relay;
original metadata probes remain a compatibility fallback.

The browser coalesces drag events, refreshes its playback grant, waits for the
first playable chunk and retries a busy encoder before replacing its stream.
Navigation or a newer seek cancels pending browser work. A failed seek shows a
retry action while retaining the previous source; a fatal playback error can
still fall back once to the original. Seeking itself does not select original
playback. Cache identities include the source revision, quality and starting
position; published chunks from different timelines cannot be mixed.
Downloads use `/api/media/download`, never an HLS rendition or the playback
endpoint's initial chunk. The server sends the complete original as bounded
sequential reads over either HTTP transport, supports byte-range resume, retains
the owner's filename, and checks source revision/size to stop mixed transfers.
Existing session, member-clip and opted-in owner-routing guards remain in place.

The watch page adds a visible seek slider and play/pause, 10-second skips,
mute/volume and fullscreen controls over the real video element. Dragging keeps
the previous play/pause state and spans the full recording duration. Play/pause
changes during preparation are retained. With the
video focused, Space/K toggles playback, arrows seek five seconds, J/L seek ten,
Home/End seek to full recording boundaries, M toggles mute and F toggles fullscreen.
Range inputs retain their native keyboard controls. The stage enters fullscreen
with its controls; supported mobile browsers can use native video fullscreen.
Native controls remain available before enhancement, and control listeners are
released when navigating away.

The owner deduplicates viewers of the same source/rendition/offset, runs at most
two HLS encoders, and returns retryable 503 responses when busy. Initial masters
start only the low rendition; another rendition starts when selected. A new seek
can replace this recording's least recently requested encoder, without cancelling
other recordings' encoders. Cancellation drains reader callbacks safely, freezes
its valid published prefix with ENDLIST, and retains those chunks. A viewer that
reaches an interrupted prefix's end requests encoded playback from its current
position. ENDLIST therefore closes the current HLS timeline, which can be shorter
than the complete source recording. Unfinished jobs stop
after 90 seconds without playlist/chunk requests. Each rendition is capped at
5 GiB; completed and old HLS entries share the existing 10 GiB cache trimming
policy with its recent-playback retention window. Partial process-crash caches
are rebuilt, write failures are propagated, and source changes invalidate cache
identities. Listing a library no longer queues whole-file MP4 encodes.

Runtime implementation is in `RecordingDirectoryClient.swift` and
`AppModel+RecordingCoordination.swift`; local indexing/encoding stays in
`RecordingsKit`. No Ruru build dependency or application-specific Ruru authority
code is required.

## Recording comments

The watch page and member clip player have a basic comment log: plain text,
author and time, with an explicit Refresh action. Comments require a signed-in
browser session; media URL grants cannot read or post them. Admins can post,
read-only viewers can read, and members can read/post only on clips the existing
participant permission check allows. CSRF and the active-Primary write gate apply.
Author identity comes from the session, not the submitted form.

Comments for local and shared clips are saved by the active WebUI in
`recording-comments.json` under SwiftBot's Application Support folder, keyed by
library identity and recording ID. Each post is atomically persisted before
success is returned, carries a retry ID to avoid duplicate posts, and logs its
comment ID and author ID to Activity without copying the comment text. The file
joins the existing revisioned SwiftMesh configuration snapshot and is reread
after import or restart; the recording owner and Ruru do not store comments.
As with other shared state, an abrupt owner failure can lose posts newer than
the last successful sync. Comments do not add video transfers or restart playback.

Comments are append-only, with a 2,000 UTF-16-unit text limit, 200 comments per
clip, 10,000 overall and an 8 MiB file limit. Full, corrupt or unwritable logs
produce a visible error and retain existing history. Edits, deletion and replies
are outside this basic implementation.

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
