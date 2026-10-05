/** Formatting and axis helpers for the dashboard (kept apart from the components so they're easy to test). */

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/**
 * "2026-09-24" -> "Sep 24". Read straight from the string: new Date() would
 * treat it as UTC midnight and could show the previous day in the Americas.
 */
export function formatDay(date: string): string {
  const [, month, day] = date.split('-').map(Number)
  return `${MONTHS[month - 1]} ${day}`
}

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]

/** "2026-09" -> "September 2026". */
export function monthLabel(month: string): string {
  const [year, m] = month.split('-').map(Number)
  return `${MONTH_NAMES[m - 1]} ${year}`
}

/** "2026-09" moved by n months: shiftMonth("2026-01", -1) === "2025-12". */
export function shiftMonth(month: string, n: number): string {
  const [year, m] = month.split('-').map(Number)
  const total = year * 12 + (m - 1) + n
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`
}

/** Short axis labels: 2500000 cents -> "$25K". */
export function formatCompact(cents: number): string {
  const dollars = cents / 100
  const abs = Math.abs(dollars)
  const sign = dollars < 0 ? '-' : ''
  if (abs >= 1_000_000) return `${sign}$${+(abs / 1_000_000).toFixed(1)}M`
  if (abs >= 1_000) return `${sign}$${+(abs / 1_000).toFixed(1)}K`
  return `${sign}$${abs.toFixed(0)}`
}

/**
 * Round, evenly spaced axis values covering [min, max]: steps of 1, 2 or 5 x
 * 10^n. The first tick is at or below min and the last at or above max, so
 * the line never runs off the top or bottom of the chart.
 */
export function niceTicks(min: number, max: number, count = 4): number[] {
  const span = max - min || 1
  const raw = span / count
  const magnitude = 10 ** Math.floor(Math.log10(raw))
  const step = [1, 2, 5, 10].map((m) => m * magnitude).find((s) => s >= raw) ?? raw
  const first = Math.floor(min / step)
  const last = Math.ceil(max / step)
  return Array.from({ length: last - first + 1 }, (_, i) => (first + i) * step)
}
