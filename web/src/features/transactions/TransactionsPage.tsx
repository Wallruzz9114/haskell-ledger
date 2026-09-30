import { useEffect, useState } from 'react'
import {
  errorMessage,
  useListAccountsQuery,
  useTransactionsInfiniteQuery,
  type User,
} from '../../app/api'
import { formatCents } from '../../app/money'

/** "Sep 24, 2026, 9:00 AM" in the viewer's own time zone. */
function formatWhen(iso: string): string {
  return new Date(iso).toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}

/**
 * Every transaction across your accounts, newest first: search, filter by
 * account, and load 25 more at a time.
 */
export function TransactionsPage({ user }: Readonly<{ user: User }>) {
  const [typed, setTyped] = useState('')
  const [search, setSearch] = useState('')
  const [account, setAccount] = useState('')
  const { data: accounts = [] } = useListAccountsQuery()
  // The same accounts the API covers: your own, or every customer account
  // for an admin (never "external").
  const choices = accounts.filter((a) =>
    user.role === 'admin' ? a.kind === 'Customer' : a.owner === user.username,
  )

  // Wait until typing pauses for 300 ms before searching, so the API isn't
  // asked once per keystroke.
  useEffect(() => {
    const timer = setTimeout(() => setSearch(typed.trim()), 300)
    return () => clearTimeout(timer)
  }, [typed])

  const { data, error, isLoading, isFetchingNextPage, hasNextPage, fetchNextPage } =
    useTransactionsInfiniteQuery({ q: search, account })
  const items = data?.pages.flatMap((page) => page.items) ?? []

  return (
    <section className="card">
      <h2>Transactions</h2>
      <div className="filters">
        <input
          type="search"
          aria-label="Search transactions"
          placeholder="Search memos and names"
          value={typed}
          onChange={(e) => setTyped(e.target.value)}
        />
        <select aria-label="Account" value={account} onChange={(e) => setAccount(e.target.value)}>
          <option value="">All accounts</option>
          {choices.map((a) => (
            <option key={a.id} value={a.id}>
              {a.name}
            </option>
          ))}
        </select>
      </div>

      {error && <p className="error">{errorMessage(error)}</p>}
      {isLoading && <p className="muted">Loading…</p>}
      {!isLoading && !error && items.length === 0 && (
        <p className="muted">
          {search ? `No transactions match “${search}”.` : 'No transactions yet.'}
        </p>
      )}

      {items.length > 0 && (
        <table className="transactions">
          <thead>
            <tr>
              <th>When</th>
              <th>To / from</th>
              <th>Account</th>
              <th className="right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {items.map((t) => (
              <tr key={`${t.transfer}-${t.account}`}>
                <td className="when">
                  <time dateTime={t.createdAt}>{formatWhen(t.createdAt)}</time>
                </td>
                <td>
                  <div className="cell-stack">
                    <span>
                      {t.amountCents < 0 ? 'To ' : 'From '}
                      <strong>{t.counterpartyName}</strong>
                    </span>
                    {t.memo && <small className="muted memo">{t.memo}</small>}
                  </div>
                </td>
                <td className="muted">{t.accountName}</td>
                <td
                  className={t.amountCents < 0 ? 'right amount negative' : 'right amount positive'}
                >
                  {t.amountCents > 0 ? '+' : ''}
                  {formatCents(t.amountCents)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {hasNextPage && (
        <button
          type="button"
          className="secondary load-more"
          onClick={() => fetchNextPage()}
          disabled={isFetchingNextPage}
        >
          {isFetchingNextPage ? 'Loading…' : 'Load more'}
        </button>
      )}
    </section>
  )
}
