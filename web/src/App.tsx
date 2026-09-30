import { errorMessage, isUnauthorized, useMeQuery, type User } from './app/api'
import { AccountEntries } from './features/accounts/AccountEntries'
import { AccountsPanel } from './features/accounts/AccountsPanel'
import { AssignOwnerForm } from './features/accounts/AssignOwnerForm'
import { LoginPage } from './features/auth/LoginPage'
import { UserBar } from './features/auth/UserBar'
import { DepositForm } from './features/transfers/DepositForm'
import { TransferForm } from './features/transfers/TransferForm'

/**
 * Asks the API who is logged in (GET /api/me), then shows the login page or
 * the ledger. Any 401 later on re-checks this, so an expired session lands
 * back on the login page.
 */
export default function App() {
  const { data: me, error, isLoading, isFetching, refetch } = useMeQuery()

  if (isLoading) {
    return (
      <div className="page">
        <p className="muted">Loading…</p>
      </div>
    )
  }
  if (error && !isUnauthorized(error)) {
    // The API couldn't be reached (or failed). Say so, and offer a retry
    // instead of leaving a dead end that needs a page reload.
    return (
      <div className="page narrow">
        <h1>Ledger</h1>
        <section className="card stack" role="alert">
          <p className="error">{errorMessage(error)}</p>
          <button type="button" onClick={() => refetch()} disabled={isFetching}>
            {isFetching ? 'Trying…' : 'Try again'}
          </button>
        </section>
      </div>
    )
  }
  if (!me || error) return <LoginPage />
  return <Ledger user={me} />
}

function Ledger({ user }: Readonly<{ user: User }>) {
  const isAdmin = user.role === 'admin'
  return (
    <div className="page">
      <header className="topbar">
        <div>
          <h1>Ledger</h1>
          <p className="muted">
            A double-entry ledger: Haskell API, React + TypeScript + Redux front end.
          </p>
        </div>
        <UserBar user={user} />
      </header>
      <main className="grid">
        <div className="column">
          <AccountsPanel user={user} />
          {isAdmin && <DepositForm />}
          {isAdmin && <AssignOwnerForm />}
        </div>
        <div className="column">
          {/* Admins can see every account but send from none of them. */}
          {!isAdmin && <TransferForm user={user} />}
          <AccountEntries />
        </div>
      </main>
    </div>
  )
}
