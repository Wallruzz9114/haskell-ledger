import { afterEach, describe, expect, it, vi } from 'vitest'
import { newIdempotencyKey } from './idempotency'

describe('newIdempotencyKey', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('makes a version 4 UUID', () => {
    expect(newIdempotencyKey()).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    )
  })

  it('is different every time', () => {
    const keys = new Set(Array.from({ length: 1000 }, newIdempotencyKey))
    expect(keys.size).toBe(1000)
  })

  it('works where crypto.randomUUID is missing (plain HTTP pages)', () => {
    // Keep getRandomValues, drop randomUUID, like a non-HTTPS page.
    vi.stubGlobal('crypto', { getRandomValues: crypto.getRandomValues.bind(crypto) })
    expect(newIdempotencyKey()).toMatch(/^[0-9a-f-]{36}$/)
  })
})
