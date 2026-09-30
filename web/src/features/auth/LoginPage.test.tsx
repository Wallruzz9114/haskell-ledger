import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import { apiError, fakeApi } from '../../test/fakeApi'
import { renderWithStore } from '../../test/render'
import { LoginPage } from './LoginPage'

async function tryLogin() {
  renderWithStore(<LoginPage />)
  await userEvent.type(screen.getByLabelText('Username'), 'alice')
  await userEvent.type(screen.getByLabelText('Password'), 'nope')
  await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
}

describe('LoginPage', () => {
  it('shows the message for a wrong password', async () => {
    fakeApi({
      'POST /api/login': () => ({
        status: 401,
        body: apiError('invalid_credentials', 'Wrong username or password.'),
      }),
    })
    await tryLogin()
    expect(await screen.findByText('Wrong username or password.')).toBeInTheDocument()
  })

  it('shows the lockout message after too many attempts', async () => {
    fakeApi({
      'POST /api/login': () => ({
        status: 429,
        body: apiError('too_many_attempts', 'Too many failed logins. Please wait and try again.'),
      }),
    })
    await tryLogin()
    expect(await screen.findByText(/Too many failed logins/)).toBeInTheDocument()
  })
})
