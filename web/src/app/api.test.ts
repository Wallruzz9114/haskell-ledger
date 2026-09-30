import { describe, expect, it } from 'vitest'
import { errorMessage, isUnauthorized } from './api'

describe('errorMessage', () => {
  it("shows the API's own message", () => {
    const err = {
      status: 422,
      data: { error: 'insufficient_funds', message: 'Insufficient funds.' },
    }
    expect(errorMessage(err)).toBe('Insufficient funds.')
  })

  it('adds the reference for unexpected failures, to match the server log', () => {
    const err = {
      status: 503,
      data: {
        error: 'service_unavailable',
        message: 'Try again in a moment.',
        requestId: '3f9a1c2b',
      },
    }
    expect(errorMessage(err)).toBe('Try again in a moment. (reference 3f9a1c2b)')
  })

  it('falls back to a hint when the API sent nothing useful', () => {
    expect(errorMessage({ status: 'FETCH_ERROR', error: 'Failed to fetch' })).toMatch(
      /Couldn't reach the server/,
    )
  })

  it('is null when there is no error', () => {
    expect(errorMessage(undefined)).toBeNull()
  })
})

describe('isUnauthorized', () => {
  it('recognises a 401 and nothing else', () => {
    expect(isUnauthorized({ status: 401, data: {} })).toBe(true)
    expect(isUnauthorized({ status: 403, data: {} })).toBe(false)
    expect(isUnauthorized(undefined)).toBe(false)
  })
})
