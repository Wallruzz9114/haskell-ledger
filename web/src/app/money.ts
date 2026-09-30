/**
 * Money helpers. Money is integer cents everywhere, mirroring the backend:
 * these never use floating-point arithmetic on amounts.
 */

/** The largest amount one transfer may move, in cents ($1,000,000,000.00). Matches the API. */
export const MAX_AMOUNT_CENTS = 100_000_000_000

/** Integer cents to a display string: 125050 -> "$1,250.50", -5 -> "-$0.05". */
export function formatCents(cents: number): string {
  const sign = cents < 0 ? '-' : ''
  const abs = Math.abs(cents)
  const dollars = Math.floor(abs / 100).toLocaleString('en-US')
  const rest = String(abs % 100).padStart(2, '0')
  return `${sign}$${dollars}.${rest}`
}

/**
 * Parse what someone typed ("1,234.56", "$20", "0.5") into cents, without
 * floating-point rounding. Null if it isn't a positive amount within the limit.
 */
export function parseDollarsToCents(input: string): number | null {
  const cleaned = input.replace(/[$,\s]/g, '')
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(cleaned)
  if (!match) return null
  const whole = Number(match[1])
  const fraction = Number((match[2] ?? '').padEnd(2, '0'))
  const cents = whole * 100 + fraction
  return cents > 0 && cents <= MAX_AMOUNT_CENTS ? cents : null
}
