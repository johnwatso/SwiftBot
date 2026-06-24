// Client-side search logic for SwiftBot Help Center

document.addEventListener('DOMContentLoaded', () => {
  const searchInput = document.getElementById('help-search');
  if (!searchInput) return;

  const searchWrap = searchInput.closest('.search-wrap');
  if (!searchWrap) return;

  // Create search dropdown element dynamically
  const dropdown = document.createElement('div');
  dropdown.className = 'search-results-dropdown';
  searchWrap.appendChild(dropdown);

  // Detect relative prefix based on path depth.
  // On the help index (/help/ or /help/index.html) links are root-relative to help.
  // Inside an article (/help/<topic>/) we need to step up one level.
  let prefix = '';
  const pathParts = window.location.pathname.split('/');
  const helpIndex = pathParts.indexOf('help');
  if (helpIndex !== -1 && helpIndex < pathParts.length - 2) {
    prefix = '../';
  }

  let highlightedIndex = -1;
  let currentResults = [];

  searchInput.addEventListener('input', () => {
    const query = searchInput.value.trim().toLowerCase();
    if (!query) {
      hideDropdown();
      return;
    }

    // Match query against search index
    currentResults = searchIndex
      .map(item => {
        let score = 0;
        const titleLower = item.title.toLowerCase();
        const categoryLower = item.category.toLowerCase();
        const snippetLower = item.snippet.toLowerCase();
        const keywordsLower = item.keywords.toLowerCase();

        // 1. Exact match on title or keywords
        if (titleLower === query) score += 100;
        else if (titleLower.includes(query)) score += 40;

        // 2. Exact match on category
        if (categoryLower.includes(query)) score += 20;

        // 3. Keyword matches
        const queryWords = query.split(/\s+/);
        let wordMatches = 0;
        queryWords.forEach(word => {
          if (keywordsLower.includes(word)) {
            score += 15;
            wordMatches++;
          }
          if (titleLower.includes(word)) {
            score += 10;
          }
          if (snippetLower.includes(word)) {
            score += 5;
          }
        });

        // Boost score if all words match
        if (wordMatches === queryWords.length) {
          score += 25;
        }

        return { ...item, score };
      })
      .filter(item => item.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 6); // Cap at 6 results

    renderResults(currentResults, query);
  });

  // Keyboard navigation
  searchInput.addEventListener('keydown', (e) => {
    const items = dropdown.querySelectorAll('.search-result-item');
    if (!items.length) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      highlightedIndex = (highlightedIndex + 1) % items.length;
      updateHighlight(items);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      highlightedIndex = (highlightedIndex - 1 + items.length) % items.length;
      updateHighlight(items);
    } else if (e.key === 'Enter') {
      if (highlightedIndex >= 0 && highlightedIndex < items.length) {
        e.preventDefault();
        items[highlightedIndex].querySelector('a').click();
      }
    } else if (e.key === 'Escape') {
      hideDropdown();
      searchInput.blur();
    }
  });

  // Close dropdown when clicking outside
  document.addEventListener('click', (e) => {
    if (!searchWrap.contains(e.target)) {
      hideDropdown();
    }
  });

  // Show dropdown again on focus if there is input
  searchInput.addEventListener('focus', () => {
    if (searchInput.value.trim()) {
      searchInput.dispatchEvent(new Event('input'));
    }
  });

  function renderResults(results, query) {
    dropdown.innerHTML = '';
    highlightedIndex = -1;

    if (results.length === 0) {
      dropdown.innerHTML = `<div class="search-no-results">No results found for "${escapeHtml(query)}"</div>`;
      dropdown.style.display = 'block';
      return;
    }

    const list = document.createElement('ul');
    list.className = 'search-results-list';

    results.forEach((item) => {
      const li = document.createElement('li');
      li.className = 'search-result-item';

      const fullUrl = prefix + item.url;

      li.innerHTML = `
        <a href="${fullUrl}" class="search-result-link">
          <div class="search-result-category">${escapeHtml(item.category)}</div>
          <div class="search-result-title">${escapeHtml(item.title)}</div>
          <div class="search-result-snippet">${escapeHtml(item.snippet)}</div>
        </a>
      `;
      list.appendChild(li);
    });

    dropdown.appendChild(list);
    dropdown.style.display = 'block';
  }

  function updateHighlight(items) {
    items.forEach((item, index) => {
      if (index === highlightedIndex) {
        item.classList.add('highlighted');
        item.scrollIntoView({ block: 'nearest' });
      } else {
        item.classList.remove('highlighted');
      }
    });
  }

  function hideDropdown() {
    dropdown.style.display = 'none';
    highlightedIndex = -1;
  }

  function escapeHtml(str) {
    return str
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }
});
