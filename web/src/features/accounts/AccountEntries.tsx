import { skipToken } from '@reduxjs/toolkit/query'
import { errorMessage, useAccountEntriesQuery } from '../../app/api'
import { useAppSelector } from '../../app/hooks'
import { formatCents } from '../../app/money'

/** The double-entry view: every row is one side of a transfer. */
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
        <table>
          <thead>
            <tr>
              <th>Transfer</th>
              <th className="right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e) => (
              <tr key={`${e.transfer}-${e.account}`}>
                <td>#{e.transfer}</td>
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
