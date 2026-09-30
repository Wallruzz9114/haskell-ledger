import { useState, type SubmitEvent } from 'react'
import { errorMessage, useListAccountsQuery, useTransferMutation, type User } from '../../app/api'
import { formatCents, parseDollarsToCents } from '../../app/money'
import { useDraftKey } from '../../app/useDraftKey'

/**
 * Send money from one of your accounts to any account id.
 *
 * One idempotency key per draft (see useDraftKey): resending the same
 * details reuses it, so a retry can't move money twice; changing any detail
 * or finishing a transfer starts a new one.
 */
export function TransferForm({ user }: Readonly<{ user: User }>) {
  const { data: accounts = [] } = useListAccountsQuery()
  const mine = accounts.filter((a) => a.owner === user.username)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [amount, setAmount] = useState('')
  const [memo, setMemo] = useState('')
  const { key: draftKey, renew, edited } = useDraftKey()
  const [localError, setLocalError] = useState<string | null>(null)
  const [transfer, { isLoading, error, data, reset }] = useTransferMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    const cents = parseDollarsToCents(amount)
    if (cents === null) {
      setLocalError('Enter a positive amount, e.g. 1,250.00')
      return
    }
    setLocalError(null)
    const result = await transfer({
      from,
      to: to.trim(),
      amountCents: cents,
      memo,
      idempotencyKey: draftKey,
    })
    if ('data' in result) {
      setAmount('')
      setMemo('')
      renew()
    }
  }

  return (
    <section className="card">
      <h2>Send money</h2>
      <form className="stack" onSubmit={submit} onChange={() => data && reset()}>
        <label>
          <span>From</span>
          <select value={from} onChange={(e) => edited(setFrom)(e.target.value)} required>
            <option value="">Choose one of your accounts</option>
            {mine.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name} ({formatCents(a.balanceCents)})
              </option>
            ))}
          </select>
        </label>
        <label>
          <span>To (any account id)</span>
          {/* The datalist suggests your own accounts but allows any id,
              e.g. another company's account you're paying. */}
          <input
            list="transfer-targets"
            placeholder="e.g. globex-ops"
            value={to}
            onChange={(e) => edited(setTo)(e.target.value)}
            required
          />
        </label>
        <datalist id="transfer-targets">
          {mine
            .filter((a) => a.id !== from)
            .map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
              </option>
            ))}
        </datalist>
        <label>
          <span>Amount (USD)</span>
          <input
            inputMode="decimal"
            placeholder="0.00"
            value={amount}
            onChange={(e) => edited(setAmount)(e.target.value)}
            required
          />
        </label>
        <label>
          <span>Memo</span>
          <input
            placeholder="Optional"
            value={memo}
            onChange={(e) => edited(setMemo)(e.target.value)}
          />
        </label>
        <button type="submit" disabled={isLoading}>
          {isLoading ? 'Sending…' : 'Send'}
        </button>
        <p className="hint">Idempotency key: {draftKey.slice(0, 8)}… (safe to retry)</p>
        {localError && <p className="error">{localError}</p>}
        {error && <p className="error">{errorMessage(error)}</p>}
        {data && (
          <p className="success">
            Sent {formatCents(data.amount)} as transfer #{data.id}.
          </p>
        )}
      </form>
    </section>
  )
}
