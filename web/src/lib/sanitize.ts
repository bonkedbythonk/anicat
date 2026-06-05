const DANGEROUS_TAGS = /<\/?(script|iframe|object|embed|form|input|button|link|meta|style|applet|frame|frameset|ilayer|layer|bgsound|title|base)[^>]*>/gi;
const EVENT_HANDLERS = /\s+on\w+\s*=\s*(["'][^"']*["']|[^\s>]*)/gi;
const JAVASCRIPT_URL = /(?:href|src|action|formaction)\s*=\s*(["'])javascript:/gi;

export function sanitizeHtml(html: string): string {
  if (!html) return "";
  return html
    .replace(DANGEROUS_TAGS, "")
    .replace(EVENT_HANDLERS, "")
    .replace(JAVASCRIPT_URL, '$1#');
}
