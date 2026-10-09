/** Only same-site paths, so ?from=https://evil.com cannot redirect users off the app. */
export function safeRedirect(from: string | string[] | undefined, fallback = '/') {
  return typeof from === 'string' && from.startsWith('/') && !from.startsWith('//') ? from : fallback
}
