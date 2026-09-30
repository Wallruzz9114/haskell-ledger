import { useState, type SubmitEvent } from 'react'
import {
  errorMessage,
  useListAccountsQuery,
  useOpenAccountMutation,
  type User,
} from '../../app/api'
import { useAppDispatch, useAppSelector } from '../../app/hooks'
import { formatCents } from '../../app/money'
import { selectAccount } from '../../app/store'

/** The accounts this user can see: their own, or every account for an admin. */
export function AccountsPanel({ user }: Readonly<{ user: User }>) {
  const { data: accounts = [], isLoading, error } = useListAccountsQuery()
  const selected = useAppSelector((s) => s.ui.selectedAccountId)
  const dispatch = useAppDispatch()
  const isAdmin = user.role === 'admin'

  return (
    <section className="card">
      <h2>{isAdmin ? 'All accounts' : 'Your accounts'}</h2>
      {isLoading && <p className="muted">Loading…</p>}
      {error && <p className="error">{errorMessage(error)}</p>}
      {!isLoading && !error && accounts.length === 0 && (
        <p className="muted">No accounts yet. Open one below.</p>
      )}
      <ul className="account-list">
        {accounts.map((a) => (
          <li key={a.id}>
            <button
              type="button"
              className={`account ${selected === a.id ? 'selected' : ''}`}
              onClick={() => dispatch(selectAccount(a.id))}
            >
              <span>
                <strong>{a.name}</strong>
                <small className="muted">
                  {a.id}
                  {a.kind === 'External' && ' · outside the ledger'}
                  {isAdmin && a.kind === 'Customer' && ` · ${a.owner ?? 'no owner'}`}
                </small>
              </span>
              <span className={a.balanceCents < 0 ? 'amount negative' : 'amount'}>
                {formatCents(a.balanceCents)}
              </span>
            </button>
          </li>
        ))}
      </ul>
      <OpenAccountForm isAdmin={isAdmin} />
    </section>
  )
}

function OpenAccountForm({ isAdmin }: Readonly<{ isAdmin: boolean }>) {
  const [id, setId] = useState('')
  const [name, setName] = useState('')
  const [owner, setOwner] = useState('')
  const [openAccount, { isLoading, error, reset }] = useOpenAccountMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    const result = await openAccount({
      id: id.trim(),
      name: name.trim(),
      // Customers always open accounts for themselves; admins name the owner.
      ...(isAdmin ? { owner: owner.trim() } : {}),
    })
    if ('data' in result) {
      setId('')
      setName('')
      setOwner('')
      reset()
    }
  }

  return (
    <form className="inline-form" onSubmit={submit} aria-label="Open account">
      <input
        placeholder="account-id"
        aria-label="Account id"
        value={id}
        onChange={(e) => setId(e.target.value)}
        required
      />
      <input
        placeholder="Display name"
        aria-label="Display name"
        value={name}
        onChange={(e) => setName(e.target.value)}
        required
      />
      {isAdmin && (
        <input
          placeholder="owner username"
          aria-label="Owner"
          value={owner}
          onChange={(e) => setOwner(e.target.value)}
          required
        />
      )}
      <button type="submit" disabled={isLoading}>
        Open account
      </button>
      {error && <p className="error">{errorMessage(error)}</p>}
    </form>
  )
}
