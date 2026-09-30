import { skipToken } from '@reduxjs/toolkit/query'
import { errorMessage, useAccountEntriesQuery } from '../../app/api'
import { useAppSelector } from '../../app/hooks'
import { formatCents } from '../../app/money'

/** "Sep 29, 2026, 6:05 PM" in the viewer's own time zone. */
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
 * The double-entry view: every row is one side of a transfer, with the
 * account on the other side, the memo and when it happened.
 */
export function AccountEntries() {
  const selected = useAppSelector((s) => s.ui.selectedAccountId)
  // skipToken: don't fetch anything until an account is selected.
  const { data: entries = [], error } = useAccountEntriesQuery(selected ?? skipToken)

  return (
    <section className="card">
      <h2>Entries {selected && <small className="muted">· {selected}</small>}</h2>
      {!selected && <p className="muted">Select an account to see its ledger entries.</p>}
      {error && <p className="error">{errorMessage(error)}</p>}
      {selected && entries.length === 0 && !error && <p className="muted">No entries yet.</p>}
      {entries.length > 0 && (
        <table className="entries">
          <thead>
            <tr>
              <th>When</th>
              <th>Details</th>
              <th className="right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e) => (
              <tr key={`${e.transfer}-${e.account}`}>
                <td className="when">
                  {/* A div inside the cell does the stacking: making the
                      <td> itself a flex box would stop it acting as a
                      table cell and break the row. */}
                  <div className="cell-stack">
                    <time dateTime={e.createdAt}>{formatWhen(e.createdAt)}</time>
                    <small className="muted">#{e.transfer}</small>
                  </div>
                </td>
                <td>
                  <div className="cell-stack">
                    {/* Money out goes "to" the other account; money in comes "from" it. */}
                    <span>
                      {e.amount < 0 ? 'To ' : 'From '}
                      <strong>{e.counterparty}</strong>
                    </span>
                    {e.memo && <small className="muted memo">{e.memo}</small>}
                  </div>
                </td>
                <td className={e.amount < 0 ? 'right amount negative' : 'right amount positive'}>
                  {e.amount > 0 ? '+' : ''}
                  {formatCents(e.amount)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
