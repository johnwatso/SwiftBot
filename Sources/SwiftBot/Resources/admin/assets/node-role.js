// A role change replaces the browser surface, never the HTTP listener.
// Public liveness is enough: no session, bot credentials or admin data needed.
(() => {
  let checking = false;
  let navigating = false;
  async function checkRole() {
    if (checking || navigating || document.visibilityState === 'hidden') return;
    checking = true;
    try {
      const response = await fetch('/live', {
        headers: { Accept: 'application/json' }, credentials: 'omit',
        cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(5000)
      });
      if (!response.ok) throw new Error('Status unavailable');
      const status = await response.json();
      document.dispatchEvent(new CustomEvent('swiftbot-node-status', { detail: status }));
      // Missing on older servers: leave the current page alone.
      if (typeof status.isFailoverManagedNode !== 'boolean') return;
      const standbyPage = document.body.dataset.nodePage === 'standby';
      if (standbyPage !== status.isFailoverManagedNode) {
        navigating = true;
        location.reload();
      }
    } catch (_) {
      document.dispatchEvent(new CustomEvent('swiftbot-node-status-unavailable'));
    } finally {
      checking = false;
    }
  }
  document.addEventListener('visibilitychange', checkRole);
  window.addEventListener('online', checkRole);
  window.addEventListener('pageshow', checkRole);
  setInterval(checkRole, 10000);
  checkRole();
})();
