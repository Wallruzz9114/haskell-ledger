import { useState, type SubmitEvent } from 'react'
import { errorMessage, useDepositMutation, useListAccountsQuery } from '../../app/api'
import { parseDollarsToCents } from '../../app/money'

/** Admin only: bring money into the ledger from outside. */
export function DepositForm() {
  const { data: accounts = [] } = useListAccountsQuery()
  const customerAccounts = accounts.filter((a) => a.kind === 'Customer')
  const [to, setTo] = useState('')
  const [amount, setAmount] = useState('')
  const [localError, setLocalError] = useState<string | null>(null)
  const [deposit, { isLoading, error }] = useDepositMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    const cents = parseDollarsToCents(amount)
    if (cents === null) {
      setLocalError('Enter a positive amount, e.g. 1,250.00')
      return
    }
    setLocalError(null)
    const result = await deposit({ to, amountCents: cents })
    if ('data' in result) setAmount('')
  }

  return (
    <section className="card">
      <h2>Deposit</h2>
      <form className="inline-form" onSubmit={submit}>
        <select
          aria-label="Into account"
          value={to}
          onChange={(e) => setTo(e.target.value)}
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
          onChange={(e) => setAmount(e.target.value)}
          required
        />
        <button type="submit" disabled={isLoading}>
          Deposit
        </button>
        {localError && <p className="error">{localError}</p>}
        {error && <p className="error">{errorMessage(error)}</p>}
      </form>
    </section>
  )
}
