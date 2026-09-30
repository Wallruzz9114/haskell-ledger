import { useState, type SubmitEvent } from 'react'
import { errorMessage, useLoginMutation } from '../../app/api'

export function LoginPage() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [login, { isLoading, error }] = useLoginMutation()

  async function submit(e: SubmitEvent<HTMLFormElement>) {
    e.preventDefault()
    // On success the 'Me' query refetches and App switches to the ledger.
    await login({ username: username.trim(), password })
  }

  return (
    <div className="page narrow">
      <h1>Ledger</h1>
      <section className="card">
        <h2>Log in</h2>
        <form className="stack" onSubmit={submit}>
          <label>
            <span>Username</span>
            <input
              autoComplete="username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
            />
          </label>
          <label>
            <span>Password</span>
            <input
              type="password"
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </label>
          <button type="submit" disabled={isLoading}>
            {isLoading ? 'Logging in…' : 'Log in'}
          </button>
          {error && <p className="error">{errorMessage(error)}</p>}
        </form>
      </section>
      <p className="hint">
        Demo users: <strong>alice</strong> (Acme), <strong>bob</strong> (Globex) and{' '}
        <strong>admin</strong>. The demo password is in the README.
      </p>
    </div>
  )
}
