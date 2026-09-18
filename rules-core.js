// rules-core.js - buildRules() and its helpers, shared by the service worker (via importScripts,
// classic SW - no ES modules) and the popup/options pages (via rules-lib.js's window.RB
// re-export). Assigns globalThis.RBCore so both contexts can reach it with no bundler.
//
// This used to be duplicated: gen-rules.mjs (Node CLI) and rules-lib.js (browser) each carried
// their own byte-for-byte copy with a comment warning they "must stay mirror images". One copy
// here, imported by both, retires that duplication.
//
// buildRules(data, opts) takes an opts bag so org-specific literals (Jira host, GitHub org, repo
// aliases) are no longer hardcoded - every default below matches this project's own values
// exactly, so an unconfigured install behaves identically to before this existed.
(function (root) {
  const COLOR_HEX = {
    grey: '#888c94', blue: '#4f8cff', red: '#e5534b', yellow: '#d8a800',
    green: '#3aab57', pink: '#e0608e', purple: '#a65cd6', cyan: '#23b7c9', orange: '#e08327',
  };

  const PALETTE = ['blue', 'cyan', 'green', 'yellow', 'orange', 'red', 'pink', 'purple'];
  const colorFor = (key) => {
    let h = 0;
    for (const c of key) h = (h + c.charCodeAt(0)) % 100000;
    return PALETTE[h % PALETTE.length];
  };
  const labelFor = (t) => (!t ? '' : t.includes(':') ? t.split(':')[0].trim() : t.split(/\s+/).slice(0, 3).join(' '));
  const jiraKey = (u) => (/browse\/([A-Z0-9]+-\d+)/.exec(u || '') || [])[1] || null;
  const agiletestIssueId = (u) => (/selectedIssueId=(\d+)/.exec(u || '') || [])[1] || null;

  // stories.json is hand-edited and script-written, and a single-app story has more than once been
  // saved as "apps": "one-app" instead of ["one-app"]. That crashed buildRules with
  // '.map is not a function' (surfacing only as a bare "failed" in the popup), and a bare-string
  // jira_stories was worse: for..of iterated it CHARACTER BY CHARACTER and silently produced
  // garbage rules. Normalize every array-shaped field on read.
  const asArr = (v) => (Array.isArray(v) ? v.filter((x) => x != null) : v == null ? [] : [v]);

  const DEFAULT_OPTS = {
    jiraBaseUrl: 'https://vesta.atlassian.net',
    githubOrg: 'vesta-experimental',
    repoAliases: { 'ganesha-iu-internal-app': 'ganesha-ui-internal-app' },
  };

  function buildRules(data, opts) {
    const o = Object.assign({}, DEFAULT_OPTS, opts || {});
    const repoFor = (a) => (Object.prototype.hasOwnProperty.call(o.repoAliases, a) ? o.repoAliases[a] : a);
    const stories = data.stories || {};
    const out = [];
    for (const [key, s] of Object.entries(stories)) {
      const label = labelFor(s.title);
      const title = label ? `${key} ${label}` : key;
      const repos = asArr(s.apps).map(repoFor);
      const jiras = asArr(s.jira_stories);
      // Both the singular field and the plural per-concern map are in use (agiletest_url +
      // agiletest_urls: {keycloak, apps}) - read both so a story with two test cases keeps both.
      const agiletestUrls = [
        ...asArr(s.agiletest_url),
        ...(s.agiletest_urls && typeof s.agiletest_urls === 'object' ? Object.values(s.agiletest_urls) : []),
      ].filter(Boolean);
      const match = new Set([key]);
      if (s.rel) match.add(s.rel);
      for (const u of jiras) { const k = jiraKey(u); if (k) match.add(k); }
      for (const u of agiletestUrls) { const aid = agiletestIssueId(u); if (aid) match.add(aid); }
      const links = [];
      for (const u of jiras) links.push({ label: 'Jira story', url: u });
      if (s.rel) links.push({ label: `REL ${s.rel}`, url: `${o.jiraBaseUrl}/browse/${s.rel}` });
      for (const u of agiletestUrls) links.push({ label: 'AgileTest', url: u });
      for (const r of repos) links.push({ label: `GH Actions: ${r}`, url: `https://github.com/${o.githubOrg}/${r}/actions` });
      // Custom named links (Abstract, Test plan, or anything else) - a MAP (like agiletest_urls/
      // chg_numbers), not an array, written by switch-story.ps1's `links` command / the popup's
      // per-row ✎ editor. Appended last so the auto-derived links keep their existing order.
      const customLinks = s.links && typeof s.links === 'object' && !Array.isArray(s.links) ? s.links : {};
      for (const [label, url] of Object.entries(customLinks)) { if (url) links.push({ label, url }); }
      out.push({ key, title, color: colorFor(key), storyTitle: s.title || '', match: [...match], repos, links });
    }
    return { generatedAt: new Date().toISOString(), source: 'stories.json', stories: out };
  }

  root.RBCore = { COLOR_HEX, PALETTE, colorFor, labelFor, jiraKey, agiletestIssueId, asArr, buildRules, DEFAULT_OPTS };
})(typeof self !== 'undefined' ? self : this);
