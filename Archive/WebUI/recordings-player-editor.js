// Archived from Sources/SwiftBot/Resources/admin/index.html on 2026-10-02.
//
// The Recordings player's editing and export tools: the "Auto / Lower
// quality" switch, the clip trimmer (primary timeline), the multiview
// builder (secondary timeline, align, side-by-side export) and the Exports
// job list. Parked while playback was simplified to play the original file
// directly; the server endpoints (/api/media/export/clip,
// /api/media/export/multiview, /api/media/exports, /api/media/frame) and the
// helpers they use (initTimelineState, scheduleFramePreview, parseTimeInput,
// mediaExportState, mediaExportJobs) were left in place.
//
// To bring it back, put this block back as the `mediaViewMode === 'player'`
// branch at the top of renderRecordingsView(), and restore the
// `quality=standard` / HLS choice in mediaMP4URL() and attachRecordingPlayer().

      if (mediaViewMode === 'player') {
        header.innerHTML = `
          <div class="media-player-title">
            <button id="mediaBackToLibrary" class="secondary-action" type="button"><i class="lucide" data-lucide="chevron-left"></i> Library</button>
            <div class="section-mini-title">${escapeHTML(selected ? (selected.gameName || 'Recording') : 'Recordings')}</div>
            ${selected ? `<span class="media-subtle">${escapeHTML(relativeTime(selected.modifiedAt))}</span>` : ''}
          </div>
          ${selected ? `<div class="section-actions">
            <button id="mediaQualityToggle" class="secondary-action" type="button" title="Auto adapts between hardware-encoded streaming copies. Lower quality uses the smaller copy. First playback waits for preparation.">
              <i class="lucide" data-lucide="${mediaExportState.playbackQuality === 'low' ? 'monitor-play' : 'monitor'}"></i>
              ${mediaExportState.playbackQuality === 'low' ? 'Lower quality' : 'Auto quality'}
            </button>
          </div>` : ''}
        `;

        if (!mediaExportState.secondaryID && items.length > 1) {
          const fallbackSecondary = items.find(item => item.id !== (selected?.id || ''));
          if (fallbackSecondary) mediaExportState.secondaryID = fallbackSecondary.id;
        }
        const secondaryOptions = items
          .filter(item => item.id !== (selected?.id || ''))
          .map(item => `<option value="${item.id}" ${mediaExportState.secondaryID === item.id ? 'selected' : ''}>${item.gameName || 'Unknown'} · ${formatMediaTime(item.modifiedAt)}</option>`)
          .join('');

        const jobInfo = (status) => ({
          finished: ['healthy', 'Ready'], failed: ['critical', 'Failed'], running: ['info', 'Exporting…'], queued: ['neutral', 'Queued']
        })[String(status || '').toLowerCase()] || ['neutral', String(status || '')];
        const jobsHTML = (mediaExportJobs || []).length
          ? `<div class="ub-list glass">${mediaExportJobs.slice(0, 6).map(job => {
              const [state, label] = jobInfo(job.status);
              const kind = job.kind === 'multiview' ? 'Multiview' : 'Clip';
              const detail = job.status === 'failed' && job.message ? job.message : [kind, relativeTime(job.finishedAt || job.startedAt || job.createdAt)].filter(Boolean).join(' · ');
              return `
              <div class="ub-item media-job">
                <span class="ops-dot" data-state="${state}"></span>
                <span class="ub-item-text">
                  <span class="ub-item-title">${escapeHTML(job.outputFileName || `${kind} export`)}</span>
                  <span class="ub-item-sub">${escapeHTML(detail)}</span>
                </span>
                <span class="ub-item-status">${escapeHTML(label)}</span>
              </div>`;
            }).join('')}</div>`
          : '<div class="placeholder">Clips and multiviews you export appear here.</div>';
        const others = items.filter(item => item.id !== (selected?.id || '')).slice(0, 8);
        const accessQuery = mediaAccessQuery();

        panels.innerHTML = `
          <div class="media-player">
            ${selected ? `
              <div class="media-stage">
                <video id="mediaPlayer" controls preload="metadata"></video>
              </div>
              ${clipDetailsHTML(selected)}
              <div class="media-meta">
                <span>${escapeHTML(formatFileSize(selected.sizeBytes))}</span>
                <span>${escapeHTML(selected.nodeName)} · ${escapeHTML(selected.sourceName)}</span>
                <span class="media-path" title="${escapeHTML(selected.relativePath)}">${escapeHTML(selected.relativePath)}</span>
              </div>
            ` : '<div class="placeholder">Select a recording from the library to play it.</div>'}
            ${others.length ? `
              <section class="ub-group">
                <div class="ub-group-head"><h2>More recordings</h2></div>
                <div class="media-strip">
                  ${others.map(item => `
                    <button class="media-strip-item" type="button" data-media-switch="${escapeHTML(item.id)}" title="${escapeHTML(item.fileName)}">
                      <span class="media-thumb"><img src="${item.thumbnailURL}${accessQuery}" alt="" loading="lazy" data-fallback="next-sibling"><span class="media-thumb-fallback"><i class="lucide" data-lucide="film"></i></span></span>
                      <span class="media-strip-label">${escapeHTML(item.gameName || 'Recording')}</span>
                      <span class="media-subtle">${escapeHTML(relativeTime(item.modifiedAt))}</span>
                    </button>`).join('')}
                </div>
              </section>` : ''}
            ${mediaExportStatus && !mediaExportStatus.installed ? `
              <div class="ub-notice glass" style="--notice:#f59e0b;"><i class="lucide" data-lucide="triangle-alert"></i><span><strong>Exports are unavailable on this node.</strong><br>Install ffmpeg on the Mac that stores these recordings to create clips and multiviews.</span></div>` : ''}
            <div class="media-tools">
              <section class="settings-panel glass">
                <div class="panel-title"><i class="lucide" data-lucide="scissors"></i> Clip</div>
                <div class="timeline-card">
                  <div class="field-label">Clip window</div>
                  <div class="timeline-track" data-track="primary-clip">
                    <div class="timeline-window" data-window="primary-clip">
                      <span class="timeline-handle left"></span>
                      <span class="timeline-handle right"></span>
                    </div>
                  </div>
                  <div id="primaryTimelineMetaClip" class="timeline-meta"></div>
                  <div class="timeline-actions">
                    <button id="primaryExtendClip" class="secondary-action" type="button"><i class="lucide" data-lucide="maximize-2"></i> +10s</button>
                    <button id="primaryTrimClip" class="secondary-action" type="button"><i class="lucide" data-lucide="minimize-2"></i> −10s</button>
                  </div>
                </div>
                <div class="ub-help">Drag the window or its edges. Clips can be up to 15 minutes, and the window is shared with Multiview.</div>
                <div class="media-field">
                  <div class="field-label">File name (optional)</div>
                  <input id="clipName" class="field-input" placeholder="My_clip.mp4" value="${escapeHTML(mediaExportState.clipName || '')}">
                </div>
                <div class="media-tool-actions">
                  <button id="clipExportStart" class="primary-action" type="button"><i class="lucide" data-lucide="clapperboard"></i> Create clip</button>
                </div>
              </section>
              <section class="settings-panel glass">
                <div class="panel-title"><i class="lucide" data-lucide="layout-grid"></i> Multiview</div>
                <div class="field-label">Second recording</div>
                <select id="multiSecondary" class="field-select">${secondaryOptions || '<option value="">No other recordings</option>'}</select>
                <div class="timeline-card" style="margin-top:12px;">
                  <div class="field-label">This recording</div>
                  <div class="timeline-track" data-track="primary-multi">
                    <div class="timeline-window" data-window="primary-multi">
                      <span class="timeline-handle left"></span>
                      <span class="timeline-handle right"></span>
                    </div>
                  </div>
                  <div id="primaryTimelineMetaMulti" class="timeline-meta"></div>
                </div>
                <div class="timeline-card" style="margin-top:12px;">
                  <div class="field-label">Second recording</div>
                  <div class="timeline-track" data-track="secondary">
                    <div class="timeline-window" data-window="secondary">
                      <span class="timeline-handle left"></span>
                      <span class="timeline-handle right"></span>
                    </div>
                  </div>
                  <div id="secondaryTimelineMeta" class="timeline-meta"></div>
                  <div class="timeline-actions">
                    <button id="alignSecondary" class="secondary-action" type="button"><i class="lucide" data-lucide="align-left"></i> Match clip window</button>
                  </div>
                </div>
                <div class="media-field-row">
                  <div>
                    <div class="field-label">Layout</div>
                    <div class="segmented" id="multiLayout">
                      <button data-value="stacked" class="${mediaExportState.layout === 'stacked' ? 'active' : ''}">Stacked</button>
                      <button data-value="side-by-side" class="${mediaExportState.layout === 'side-by-side' ? 'active' : ''}">Side by side</button>
                    </div>
                  </div>
                  <div>
                    <div class="field-label">Audio from</div>
                    <div class="segmented" id="multiAudio">
                      <button data-value="primary" class="${mediaExportState.audio === 'primary' ? 'active' : ''}">This one</button>
                      <button data-value="secondary" class="${mediaExportState.audio === 'secondary' ? 'active' : ''}">Second</button>
                    </div>
                  </div>
                </div>
                <div class="media-field">
                  <div class="field-label">File name (optional)</div>
                  <input id="multiName" class="field-input" placeholder="Multi_view.mp4" value="${escapeHTML(mediaExportState.multiName || '')}">
                </div>
                <div class="media-tool-actions">
                  <button id="multiExportStart" class="primary-action" type="button"><i class="lucide" data-lucide="layout-grid"></i> Create multiview</button>
                </div>
              </section>
            </div>
            <section class="ub-group">
              <div class="ub-group-head"><h2>Exports</h2></div>
              ${jobsHTML}
            </section>
          </div>
        `;

        panels.querySelectorAll('[data-media-switch]').forEach(btn => btn.addEventListener('click', () => {
          flushActiveMediaPlayback(panels.querySelector('#mediaPlayer'), 'progress');
          selectedMediaItemID = btn.dataset.mediaSwitch;
          mediaExportState.secondaryID = null;
          renderRecordingsView();
          document.querySelector('#appShell .content')?.scrollTo({ top: 0, behavior: 'smooth' });
        }));

        header.querySelector('#mediaBackToLibrary')?.addEventListener('click', () => {
          flushActiveMediaPlayback(panels.querySelector('video'), 'progress');
          mediaViewMode = 'library';
          renderRecordingsView();
        });

        header.querySelector('#mediaQualityToggle')?.addEventListener('click', () => {
          const video = panels.querySelector('video');
          const wasPlaying = video && !video.paused && !video.ended;
          const resumeAt = video ? video.currentTime : 0;
          mediaExportState.playbackQuality = mediaExportState.playbackQuality === 'low' ? 'auto' : 'low';
          renderRecordingsView();
          const refreshed = document.querySelector('section#mediaView video');
          if (refreshed) {
            const onLoaded = () => {
              try { refreshed.currentTime = resumeAt; } catch (_) {}
              if (wasPlaying) refreshed.play().catch(() => {});
              refreshed.removeEventListener('loadedmetadata', onLoaded);
            };
            refreshed.addEventListener('loadedmetadata', onLoaded);
          }
        });

        panels.querySelector('#clipExportStart')?.addEventListener('click', async () => {
          if (!selected) return;
          const start = mediaExportState.clipStartSeconds ?? parseTimeInput(mediaExportState.clipStart);
          const end = mediaExportState.clipEndSeconds ?? parseTimeInput(mediaExportState.clipEnd);
          if (start == null || end == null) {
            alert('Enter a valid start and end time.');
            return;
          }
          const token = mediaTokenFromURL(selected.streamURL);
          const name = panels.querySelector('#clipName')?.value || '';
          const response = await postJSON('/api/media/export/clip', { token, startSeconds: start, endSeconds: end, name });
          if (response?.error) {
            alert(response.error);
            return;
          }
          await loadMediaData();
          renderRecordingsView();
        });

        panels.querySelector('#multiExportStart')?.addEventListener('click', async () => {
          if (!selected) return;
          const secondaryID = panels.querySelector('#multiSecondary')?.value || '';
          if (!secondaryID) {
            alert('Select a second clip.');
            return;
          }
          const secondary = items.find(item => item.id === secondaryID);
          if (!secondary) {
            alert('Could not find the selected clip.');
            return;
          }
          const primaryToken = mediaTokenFromURL(selected.streamURL);
          const secondaryToken = mediaTokenFromURL(secondary.streamURL);
          const layout = mediaExportState.layout || 'stacked';
          const audioSource = mediaExportState.audio || 'primary';
          const start = mediaExportState.multiStartSeconds ?? parseTimeInput(mediaExportState.multiStart);
          const end = mediaExportState.multiEndSeconds ?? parseTimeInput(mediaExportState.multiEnd);
          const name = panels.querySelector('#multiName')?.value || '';
          const payload = { primaryToken, secondaryToken, layout, audioSource, startSeconds: start, endSeconds: end, name };
          const response = await postJSON('/api/media/export/multiview', payload);
          if (response?.error) {
            alert(response.error);
            return;
          }
          await loadMediaData();
          renderRecordingsView();
        });

        panels.querySelector('#clipName')?.addEventListener('input', (e) => { mediaExportState.clipName = e.target.value; });
        panels.querySelector('#multiSecondary')?.addEventListener('change', (e) => {
          mediaExportState.secondaryID = e.target.value;
          renderRecordingsView();
        });
        panels.querySelector('#multiName')?.addEventListener('input', (e) => { mediaExportState.multiName = e.target.value; });

        panels.querySelectorAll('#multiLayout button').forEach(btn => {
          btn.addEventListener('click', () => {
            mediaExportState.layout = btn.dataset.value || 'stacked';
            panels.querySelectorAll('#multiLayout button').forEach(el => el.classList.toggle('active', el === btn));
          });
        });
        panels.querySelectorAll('#multiAudio button').forEach(btn => {
          btn.addEventListener('click', () => {
            mediaExportState.audio = btn.dataset.value || 'primary';
            panels.querySelectorAll('#multiAudio button').forEach(el => el.classList.toggle('active', el === btn));
          });
        });

        panels.querySelector('#alignSecondary')?.addEventListener('click', () => {
          if (mediaExportState.clipStartSeconds == null || mediaExportState.clipEndSeconds == null) return;
          const length = mediaExportState.clipEndSeconds - mediaExportState.clipStartSeconds;
          const start = mediaExportState.clipStartSeconds;
          const end = start + length;
          mediaExportState.multiStartSeconds = start;
          mediaExportState.multiEndSeconds = end;
          mediaExportState.multiStart = formatSeconds(start);
          mediaExportState.multiEnd = formatSeconds(end);
          renderRecordingsView();
        });

        const primaryVideo = panels.querySelector('video');
        const maxLen = 15 * 60;
        const primaryToken = selected ? mediaTokenFromURL(selected.streamURL) : '';
        let primaryState = null;
        if (primaryVideo) {
          attachRecordingPlayer(primaryVideo, selected);
          bindClipDetails(panels.querySelector('.clip-details'), primaryVideo, selected, async (game) => {
            flushActiveMediaPlayback(primaryVideo, 'progress');
            mediaViewMode = 'library';
            mediaLibraryLayout = 'games';
            mediaFilterState.game = game;
            mediaFilterState.page = 1;
            await loadMediaData();
            renderRecordingsView();
            document.querySelector('#appShell .content')?.scrollTo({ top: 0 });
          });

          activeMediaPlayback.sessionID = createPlaybackSession(selected.id);
          activeMediaPlayback.itemID = selected.id;
          activeMediaPlayback.started = false;
          activeMediaPlayback.completed = false;
          activeMediaPlayback.lastSentSeconds = 0;

          primaryVideo.addEventListener('play', () => {
            if (activeMediaPlayback.started) return;
            activeMediaPlayback.started = true;
            sendMediaPlaybackEvent({
              sessionID: activeMediaPlayback.sessionID,
              itemID: activeMediaPlayback.itemID,
              event: 'started',
              watchedSeconds: Math.max(0, Math.floor(primaryVideo.currentTime || 0))
            });
          });

          primaryVideo.addEventListener('timeupdate', () => {
            const watchedSeconds = Math.max(0, Math.floor(primaryVideo.currentTime || 0));
            if (watchedSeconds - activeMediaPlayback.lastSentSeconds >= 15) {
              flushActiveMediaPlayback(primaryVideo, 'progress');
            }
          });

          primaryVideo.addEventListener('pause', () => {
            flushActiveMediaPlayback(primaryVideo, 'progress');
          });

          primaryVideo.addEventListener('ended', () => {
            if (activeMediaPlayback.completed) return;
            activeMediaPlayback.completed = true;
            flushActiveMediaPlayback(primaryVideo, 'completed');
          });

          primaryVideo.addEventListener('loadedmetadata', () => {
            const duration = primaryVideo.duration || 300;
            const state = initTimelineState(duration, maxLen);
            primaryState = state;
            if (mediaExportState.clipStartSeconds != null) {
              state.start = clamp(mediaExportState.clipStartSeconds, 0, duration - 1);
            }
            if (mediaExportState.clipEndSeconds != null) {
              state.end = clamp(mediaExportState.clipEndSeconds, state.start + 1, duration);
            }

            const syncPrimaryMeta = (next) => {
              mediaExportState.clipStartSeconds = next.start;
              mediaExportState.clipEndSeconds = next.end;
              mediaExportState.clipStart = formatSeconds(next.start);
              mediaExportState.clipEnd = formatSeconds(next.end);
              const summary = `Start ${formatSeconds(next.start)} · End ${formatSeconds(next.end)} · Length ${formatSeconds(next.end - next.start)}`;
              const metaClip = panels.querySelector('#primaryTimelineMetaClip');
              const metaMulti = panels.querySelector('#primaryTimelineMetaMulti');
              if (metaClip) metaClip.innerHTML = summary;
              if (metaMulti) metaMulti.innerHTML = summary;
            };

            attachTimeline('primary-clip', state, (next, windowEl, track) => {
              syncPrimaryMeta(next);
              const otherTrack = panels.querySelector('[data-track="primary-multi"]');
              const otherWindow = otherTrack?.querySelector('[data-window="primary-multi"]');
              if (otherTrack && otherWindow) {
                updateTimelineWindow(otherTrack, otherWindow, next);
                scheduleFramePreview(otherWindow, primaryToken, (next.start + next.end) / 2);
              }
              scheduleFramePreview(windowEl, primaryToken, (next.start + next.end) / 2);
            });

            attachTimeline('primary-multi', state, (next, windowEl, track) => {
              syncPrimaryMeta(next);
              const otherTrack = panels.querySelector('[data-track="primary-clip"]');
              const otherWindow = otherTrack?.querySelector('[data-window="primary-clip"]');
              if (otherTrack && otherWindow) {
                updateTimelineWindow(otherTrack, otherWindow, next);
                scheduleFramePreview(otherWindow, primaryToken, (next.start + next.end) / 2);
              }
              scheduleFramePreview(windowEl, primaryToken, (next.start + next.end) / 2);
            });

            syncPrimaryMeta(state);
            const clipWindow = panels.querySelector('[data-window="primary-clip"]');
            const multiWindow = panels.querySelector('[data-window="primary-multi"]');
            scheduleFramePreview(clipWindow, primaryToken, (state.start + state.end) / 2);
            scheduleFramePreview(multiWindow, primaryToken, (state.start + state.end) / 2);
          }, { once: true });
        }

        panels.querySelector('#primaryExtendClip')?.addEventListener('click', () => {
          if (!primaryState) return;
          const nextEnd = clamp(primaryState.end + 10, primaryState.start + 1, primaryState.duration);
          if (nextEnd - primaryState.start > primaryState.maxLen) {
            primaryState.end = primaryState.start + primaryState.maxLen;
          } else {
            primaryState.end = nextEnd;
          }
          const track = panels.querySelector('[data-track="primary-clip"]');
          const windowEl = track?.querySelector('[data-window="primary-clip"]');
          if (track && windowEl) updateTimelineWindow(track, windowEl, primaryState);
          const otherTrack = panels.querySelector('[data-track="primary-multi"]');
          const otherWindow = otherTrack?.querySelector('[data-window="primary-multi"]');
          if (otherTrack && otherWindow) updateTimelineWindow(otherTrack, otherWindow, primaryState);
          mediaExportState.clipStartSeconds = primaryState.start;
          mediaExportState.clipEndSeconds = primaryState.end;
          mediaExportState.clipStart = formatSeconds(primaryState.start);
          mediaExportState.clipEnd = formatSeconds(primaryState.end);
          const summary = `Start ${formatSeconds(primaryState.start)} · End ${formatSeconds(primaryState.end)} · Length ${formatSeconds(primaryState.end - primaryState.start)}`;
          const metaClip = panels.querySelector('#primaryTimelineMetaClip');
          const metaMulti = panels.querySelector('#primaryTimelineMetaMulti');
          if (metaClip) metaClip.innerHTML = summary;
          if (metaMulti) metaMulti.innerHTML = summary;
        });

        panels.querySelector('#primaryTrimClip')?.addEventListener('click', () => {
          if (!primaryState) return;
          primaryState.end = clamp(primaryState.end - 10, primaryState.start + 1, primaryState.duration);
          const track = panels.querySelector('[data-track="primary-clip"]');
          const windowEl = track?.querySelector('[data-window="primary-clip"]');
          if (track && windowEl) updateTimelineWindow(track, windowEl, primaryState);
          const otherTrack = panels.querySelector('[data-track="primary-multi"]');
          const otherWindow = otherTrack?.querySelector('[data-window="primary-multi"]');
          if (otherTrack && otherWindow) updateTimelineWindow(otherTrack, otherWindow, primaryState);
          mediaExportState.clipStartSeconds = primaryState.start;
          mediaExportState.clipEndSeconds = primaryState.end;
          mediaExportState.clipStart = formatSeconds(primaryState.start);
          mediaExportState.clipEnd = formatSeconds(primaryState.end);
          const summary = `Start ${formatSeconds(primaryState.start)} · End ${formatSeconds(primaryState.end)} · Length ${formatSeconds(primaryState.end - primaryState.start)}`;
          const metaClip = panels.querySelector('#primaryTimelineMetaClip');
          const metaMulti = panels.querySelector('#primaryTimelineMetaMulti');
          if (metaClip) metaClip.innerHTML = summary;
          if (metaMulti) metaMulti.innerHTML = summary;
        });

        const secondary = items.find(item => item.id === mediaExportState.secondaryID);
        if (secondary) {
          const probe = document.createElement('video');
          probe.src = `${secondary.streamURL}${mediaAccessQuery()}`;
          probe.preload = 'metadata';
          probe.addEventListener('loadedmetadata', () => {
            probe.pause();
            probe.removeAttribute('src');
            probe.load();
            const duration = probe.duration || 300;
            const state = initTimelineState(duration, maxLen);
            if (mediaExportState.multiStartSeconds != null) {
              state.start = clamp(mediaExportState.multiStartSeconds, 0, duration - 1);
            }
            if (mediaExportState.multiEndSeconds != null) {
              state.end = clamp(mediaExportState.multiEndSeconds, state.start + 1, duration);
            }
            const secondaryToken = mediaTokenFromURL(secondary.streamURL);
            attachTimeline('secondary', state, (next, windowEl, track) => {
              mediaExportState.multiStartSeconds = next.start;
              mediaExportState.multiEndSeconds = next.end;
              mediaExportState.multiStart = formatSeconds(next.start);
              mediaExportState.multiEnd = formatSeconds(next.end);
              const meta = panels.querySelector('#secondaryTimelineMeta');
              if (meta) {
                meta.innerHTML = `Start ${formatSeconds(next.start)} · End ${formatSeconds(next.end)} · Length ${formatSeconds(next.end - next.start)}`;
              }
              scheduleFramePreview(windowEl, secondaryToken, (next.start + next.end) / 2);
            });
            const meta = panels.querySelector('#secondaryTimelineMeta');
            if (meta) {
              meta.innerHTML = `Start ${formatSeconds(state.start)} · End ${formatSeconds(state.end)} · Length ${formatSeconds(state.end - state.start)}`;
            }
            const secondaryWindow = panels.querySelector('[data-window="secondary"]');
            scheduleFramePreview(secondaryWindow, secondaryToken, (state.start + state.end) / 2);
          }, { once: true });
        }
        refreshIcons();
        return;
      }


// ---- The HLS / prepared-copy player, as it was before direct playback ----
// (mediaMP4URL asked for `quality=standard`, which made the server transcode
// first; the HLS master playlist also had `BANDWIDTH:` where `BANDWIDTH=` is
// required, so browsers rejected it. Fix both before restoring this.)

    function mediaHLSURL(streamURL) {
      const id = mediaTokenFromURL(streamURL);
      if (!id) return '';
      const params = new URLSearchParams({ id });
      if (mediaAccessToken) params.set('token', mediaAccessToken);
      return `/api/media/hls?${params.toString()}`;
    }

    function mediaMP4URL(item) {
      const quality = mediaExportState.playbackQuality === 'low' ? '&quality=low' : '';
      return `${item.streamURL}${quality}${mediaAccessQuery()}`;
    }

    function attachRecordingPlayer(video, item) {
      if (!video || !item) return;
      destroyActiveMediaHls();

      const fallbackURL = mediaMP4URL(item);
      const hlsURL = mediaExportState.playbackQuality === 'low' ? '' : mediaHLSURL(item.streamURL);
      let didFallback = false;
      const useFallback = () => {
        if (didFallback) return;
        didFallback = true;
        destroyActiveMediaHls();
        video.src = fallbackURL;
        video.load();
      };

      if (!hlsURL) {
        useFallback();
        return;
      }

      if (video.canPlayType('application/vnd.apple.mpegurl')) {
        video.addEventListener('error', useFallback, { once: true });
        video.src = hlsURL;
        video.load();
        return;
      }

      if (window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({
          enableWorker: true,
          lowLatencyMode: false,
          manifestLoadingMaxRetry: 0,
          levelLoadingMaxRetry: 0,
          fragLoadingMaxRetry: 1
        });
        activeMediaHls = hls;
        hls.on(window.Hls.Events.ERROR, (_event, data) => {
          if (data?.fatal) useFallback();
        });
        hls.attachMedia(video);
        hls.loadSource(hlsURL);
        return;
      }

      useFallback();
    }

