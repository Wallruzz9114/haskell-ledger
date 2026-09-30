import { describe, expect, it } from 'vitest'
import { formatCompact, formatDay, monthLabel, niceTicks, shiftMonth } from './format'

describe('dashboard formatting', () => {
  it('reads days straight from the string (no time-zone shift)', () => {
    expect(formatDay('2026-09-01')).toBe('Sep 1')
    expect(formatDay('2026-12-31')).toBe('Dec 31')
  })

  it('names and moves between months, across year ends', () => {
    expect(monthLabel('2026-09')).toBe('September 2026')
    expect(shiftMonth('2026-01', -1)).toBe('2025-12')
    expect(shiftMonth('2026-12', 1)).toBe('2027-01')
    expect(shiftMonth('2026-09', -3)).toBe('2026-06')
  })

  it('writes short axis labels', () => {
    expect(formatCompact(2500000)).toBe('$25K')
    expect(formatCompact(150000000)).toBe('$1.5M')
    expect(formatCompact(-50000)).toBe('-$500')
  })

  it('picks round ticks that cover the data', () => {
    const ticks = niceTicks(0, 3991300)
    expect(ticks[0]).toBe(0)
    expect(ticks[ticks.length - 1]).toBeGreaterThanOrEqual(3991300)
    // Evenly spaced by a round step (1, 2 or 5 x a power of ten).
    const step = ticks[1] - ticks[0]
    expect(ticks.every((t, i) => t === ticks[0] + i * step)).toBe(true)
    expect([1, 2, 5]).toContain(step / 10 ** Math.floor(Math.log10(step)))
  })

  it('always reaches past the highest value (the chart once ran off the top)', () => {
    // The real case: a balance peaking at $64,613.00 got ticks up to $60K.
    for (const max of [6461300, 999, 100, 12345678]) {
      const ticks = niceTicks(0, max)
      expect(ticks[ticks.length - 1]).toBeGreaterThanOrEqual(max)
    }
    // And below the lowest, for negative balances.
    expect(niceTicks(-50000, 100000)[0]).toBeLessThanOrEqual(-50000)
  })
})
