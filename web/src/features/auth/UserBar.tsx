import type { User } from '../../app/api'
import { useLogoutMutation } from '../../app/api'

export function UserBar({ user }: Readonly<{ user: User }>) {
  const [logout, { isLoading }] = useLogoutMutation()
  return (
    <div className="userbar">
      <span>
        Signed in as <strong>{user.username}</strong>
        {user.role === 'admin' && <span className="badge">admin</span>}
      </span>
      <button type="button" className="secondary" onClick={() => logout()} disabled={isLoading}>
        Log out
      </button>
    </div>
  )
}
