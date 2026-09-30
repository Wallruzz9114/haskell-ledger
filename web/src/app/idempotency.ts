/**
 * A new random Idempotency-Key: a version 4 UUID, e.g.
 * "3f2a9c1e-8b7d-4e5f-a6b2-1c0d9e8f7a6b".
 *
 * Built from crypto.getRandomValues rather than crypto.randomUUID, because
 * browsers only offer randomUUID on HTTPS pages and localhost. Opening the
 * app over plain HTTP from another machine (http://192.168.1.20:5173, say)
 * would otherwise crash every form that sends money.
 */
export function newIdempotencyKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  // Mark it as a version 4 (random) UUID, as the UUID standard specifies.
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
