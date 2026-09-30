import { useState, type SubmitEvent } from 'react'
import { errorMessage, useListAccountsQuery, useSetOwnerMutation } from '../../app/api'

/**
 * Admin only: give a customer account an owner. Needed for accounts opened
 * before accounts had owners, which nobody can use until they get one.
 */
export function AssignOwnerForm() {
  const { data: accounts = [] } = useListAccountsQuery()
  const customerAccounts = accounts.filter((a) => a.kind === 'Customer')
  const [id, setId] = useState('')
  const [owner, setOwner] = useState('')
  const [setAccountOwner, { isLoading, error, data, reset }] = useSetOwnerMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    const result = await setAccountOwner({ id, owner: owner.trim() })
    if ('data' in result) setOwner('')
  }

  return (
    <section className="card">
      <h2>Assign owner</h2>
      <form className="inline-form" onSubmit={submit} onChange={() => data && reset()}>
        <select aria-label="Account" value={id} onChange={(e) => setId(e.target.value)} required>
          <option value="">Account</option>
          {customerAccounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.name} ({a.owner ?? 'no owner'})
            </option>
          ))}
        </select>
        <input
          placeholder="username"
          aria-label="New owner"
          value={owner}
          onChange={(e) => setOwner(e.target.value)}
          required
        />
        <button type="submit" disabled={isLoading}>
          Assign
        </button>
        {error && <p className="error">{errorMessage(error)}</p>}
        {data && (
          <p className="success">
            {data.name} now belongs to {data.owner}.
          </p>
        )}
      </form>
    </section>
  )
}
