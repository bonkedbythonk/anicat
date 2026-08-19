const ALLOWED_TAGS = new Set([
  "p", "br", "b", "i", "em", "strong", "a", "ul", "ol", "li", "span", "div",
  "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code", "sub", "sup",
]);

/**
 * Remove AniList spoiler blocks from a description.
 *
 * AniList renders `~!spoiler!~` as `<span class='markdown_spoiler'>` — but
 * `sanitizeHtml` below drops every class attribute, so a spoiler that reached
 * it would render as ordinary visible text. Cut the whole block out first,
 * counting nested spans so the matching close tag is the right one.
 */
export function stripSpoilers(html: string): string {
  if (!html) return "";
  const OPEN = /<span\s+class\s*=\s*['"]markdown_spoiler['"][^>]*>/i;
  let out = html;
  for (;;) {
    const start = out.search(OPEN);
    if (start === -1) return out;
    const openTag = out.slice(start).match(OPEN)![0];
    let depth = 1;
    let i = start + openTag.length;
    while (depth > 0 && i < out.length) {
      const nextOpen = out.indexOf("<span", i);
      const nextClose = out.indexOf("</span>", i);
      if (nextClose === -1) return out.slice(0, start); // unbalanced: drop the rest
      if (nextOpen !== -1 && nextOpen < nextClose) {
        depth += 1;
        i = nextOpen + 5;
      } else {
        depth -= 1;
        i = nextClose + 7;
      }
    }
    out = out.slice(0, start) + out.slice(i);
  }
}

export function sanitizeHtml(html: string): string {
  if (!html) return "";
  // Remove script, style, iframe, object, embed, form, input, textarea tags entirely
  html = html.replace(/<\/?(?:script|style|iframe|object|embed|form|input|textarea|select|option|noscript|meta|link)[^>]*>/gi, "");
  // Strip event handlers: on*="..." on*='...' on*=`...` on*=...
  html = html.replace(/\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*'|`[^`]*`|[^\s>]+)/gi, "");
  // Strip javascript: and data: in href/src/action
  html = html.replace(/\s+(?:href|src|action|data)\s*=\s*(?:"javascript:[^"]*"|'javascript:[^']*'|`javascript:[^`]*`|"data:[^"]*"|'data:[^']*')/gi, (m) => {
    const eq = m.indexOf("=");
    return m.substring(0, eq + 1) + '""';
  });
  // Strip all other attributes on allowed tags — keep only href on <a>
  html = html.replace(/<(\/?)(a|p|br|b|i|em|strong|ul|ol|li|span|div|h[1-6]|blockquote|pre|code|sub|sup)((?:\s+(?:href\s*=\s*"[^"]*"|class\s*=\s*"[^"]*"))?)(\s*\/?)>/gi, (match, end, tag, attrs, selfClose) => {
    // Only keep attributes we explicitly allow
    let cleanAttrs = "";
    if (tag === "a") {
      const hrefMatch = match.match(/href\s*=\s*"([^"]*)"/i);
      if (hrefMatch) {
        const url = hrefMatch[1].trim();
        if (url && !url.startsWith("javascript:") && !url.startsWith("data:") && !url.startsWith("#")) {
          cleanAttrs = ` href="${url}"`;
        }
      }
    }
    return `<${end}${tag}${cleanAttrs}${selfClose}>`;
  });
  // Strip any remaining unknown tags completely
  html = html.replace(/<\/?[^>]+>/g, "");
  return html;
}
