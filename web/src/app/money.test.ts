import { describe, expect, it } from 'vitest'
import { formatCents, MAX_AMOUNT_CENTS, parseDollarsToCents } from './money'

describe('formatCents', () => {
  it('formats dollars with separators and two decimals', () => {
    expect(formatCents(125050)).toBe('$1,250.50')
    expect(formatCents(0)).toBe('$0.00')
    expect(formatCents(100000000)).toBe('$1,000,000.00')
  })

  it('puts the sign before the dollar sign', () => {
    expect(formatCents(-5)).toBe('-$0.05')
    expect(formatCents(-7501300)).toBe('-$75,013.00')
  })
})

describe('parseDollarsToCents', () => {
  it('reads what people type, without floating-point rounding', () => {
    expect(parseDollarsToCents('1,234.56')).toBe(123456)
    expect(parseDollarsToCents('$20')).toBe(2000)
    expect(parseDollarsToCents('0.5')).toBe(50)
    // 0.1 + 0.2 style rounding would give 29 or 30.000000000000004 here.
    expect(parseDollarsToCents('0.29')).toBe(29)
  })

  it('rejects zero, negatives, too many decimals and nonsense', () => {
    for (const input of ['0', '0.00', '-5', '1.234', 'abc', '', '1e5']) {
      expect(parseDollarsToCents(input)).toBeNull()
    }
  })

  it('rejects amounts over the API maximum', () => {
    expect(parseDollarsToCents('1000000000')).toBe(MAX_AMOUNT_CENTS)
    expect(parseDollarsToCents('1000000000.01')).toBeNull()
  })
})
