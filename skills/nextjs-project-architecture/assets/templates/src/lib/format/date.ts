// Standard. Dates always formatted with an EXPLICIT time zone, so server (often UTC) and browser render
// the same text (no hydration mismatch). API sends ISO 8601 UTC; date-only values stay "YYYY-MM-DD".
const LOCALE = 'en-PH' // ADAPT
export const DISPLAY_TIME_ZONE = 'Asia/Manila' // ADAPT: merchant/user setting

const dateFmt = new Intl.DateTimeFormat(LOCALE, { dateStyle: 'medium', timeZone: DISPLAY_TIME_ZONE })
const dateTimeFmt = new Intl.DateTimeFormat(LOCALE, { dateStyle: 'medium', timeStyle: 'short', timeZone: DISPLAY_TIME_ZONE })

/** "2026-09-30T04:15:00Z" -> "Sep 30, 2026" */
export const formatDate = (iso: string) => dateFmt.format(new Date(iso))

/** "2026-09-30T04:15:00Z" -> "Sep 30, 2026, 12:15 PM" */
export const formatDateTime = (iso: string) => dateTimeFmt.format(new Date(iso))

/** Date-only "2026-09-30" -> "Sep 30, 2026". Never time-zone-convert date-only values. */
export function formatDateOnly(ymd: string) {
  const [y, m, d] = ymd.split('-').map(Number)
  return new Intl.DateTimeFormat(LOCALE, { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1)))
}
