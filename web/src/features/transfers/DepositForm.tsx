import { useState, type SubmitEvent } from 'react'
import { errorMessage, useDepositMutation, useListAccountsQuery } from '../../app/api'
import { formatCents, parseDollarsToCents } from '../../app/money'
import { useDraftKey } from '../../app/useDraftKey'

/**
 * Admin only: bring money into the ledger from outside.
 *
 * Sends an Idempotency-Key like the transfer form, so pressing Deposit again
 * after a timeout can't deposit the money twice.
 */
export function DepositForm() {
  const { data: accounts = [] } = useListAccountsQuery()
  const customerAccounts = accounts.filter((a) => a.kind === 'Customer')
  const [to, setTo] = useState('')
  const [amount, setAmount] = useState('')
  const [localError, setLocalError] = useState<string | null>(null)
  const { key, renew, edited } = useDraftKey()
  const [deposit, { isLoading, error, data, reset }] = useDepositMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    const cents = parseDollarsToCents(amount)
    if (cents === null) {
      setLocalError('Enter a positive amount, e.g. 1,250.00')
      return
    }
    setLocalError(null)
    const result = await deposit({ to, amountCents: cents, idempotencyKey: key })
    if ('data' in result) {
      setAmount('')
      renew()
    }
  }

  return (
    <section className="card">
      <h2>Deposit</h2>
      <form className="inline-form" onSubmit={submit} onChange={() => data && reset()}>
        <select
          aria-label="Into account"
          value={to}
          onChange={(e) => edited(setTo)(e.target.value)}
          required
        >
          <option value="">Into account</option>
          {customerAccounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.name}
            </option>
          ))}
        </select>
        <input
          inputMode="decimal"
          placeholder="0.00"
          aria-label="Amount"
          value={amount}
          onChange={(e) => edited(setAmount)(e.target.value)}
          required
        />
        <button type="submit" disabled={isLoading}>
          Deposit
        </button>
        {localError && <p className="error">{localError}</p>}
        {error && <p className="error">{errorMessage(error)}</p>}
        {data && (
          <p className="success">
            Deposited {formatCents(data.amount)} into {data.to}.
          </p>
        )}
      </form>
    </section>
  )
}
