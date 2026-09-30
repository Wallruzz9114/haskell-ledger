import { useCallback, useState } from 'react'
import { newIdempotencyKey } from './idempotency'

/**
 * The Idempotency-Key for a form that moves money.
 *
 * The key must stay the same while the request stays the same, so a retry
 * (double-click, timeout, "try again") can never move money twice. It must
 * change as soon as the request changes: the server remembers what it
 * answered for each key, success or refusal, and rejects the same key sent
 * with a different request (409 idempotency_key_reused).
 *
 * So: wrap each field's setter in `edited`, which also mints a new key, and
 * call `renew` after a success to start a fresh draft.
 */
export function useDraftKey() {
  const [key, setKey] = useState(newIdempotencyKey)
  const renew = useCallback(() => setKey(newIdempotencyKey()), [])
  const edited = useCallback(
    (set: (value: string) => void) => (value: string) => {
      set(value)
      setKey(newIdempotencyKey())
    },
    [],
  )
  return { key, renew, edited }
}
