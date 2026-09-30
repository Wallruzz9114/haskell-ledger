import { screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it } from 'vitest'
import App from './App'
import { accounts, alice, apiError, fakeApi } from './test/fakeApi'
import { renderWithStore } from './test/render'

describe('App', () => {
  it('shows the login page when nobody is logged in', async () => {
    fakeApi({
      'GET /api/me': () => ({ status: 401, body: apiError('unauthorized', 'Please log in.') }),
    })
    renderWithStore(<App />)
    expect(await screen.findByRole('heading', { name: 'Log in' })).toBeInTheDocument()
  })

  it('logs in, then shows only the logged-in customer’s accounts', async () => {
    let loggedIn = false
    const seen = fakeApi({
      'GET /api/me': () =>
        loggedIn
          ? { status: 200, body: alice }
          : { status: 401, body: apiError('unauthorized', 'Please log in.') },
      'POST /api/login': () => {
        loggedIn = true
        return { status: 200, body: alice }
      },
      'GET /api/accounts': () => ({ status: 200, body: accounts }),
    })
    renderWithStore(<App />)

    await userEvent.type(await screen.findByLabelText('Username'), 'alice')
    await userEvent.type(screen.getByLabelText('Password'), 'secret')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))

    expect(await screen.findByText('Your accounts')).toBeInTheDocument()
    // The account appears as a button in the list (and also as a suggestion
    // in the transfer form, so look for the button specifically).
    expect(await screen.findByRole('button', { name: /Acme Operating/ })).toBeInTheDocument()
    expect(screen.getByText('$28,253.00')).toBeInTheDocument()
    // The login request carried the credentials as JSON.
    const login = seen.find((r) => r.path === '/api/login')
    expect(login?.body).toEqual({ username: 'alice', password: 'secret' })
    expect(login?.headers.get('Content-Type')).toBe('application/json')
  })

  it('offers a retry when the API is down, instead of a dead end', async () => {
    let apiUp = false
    fakeApi({
      // A proxy in front of a stopped API answers 502 with no JSON body.
      'GET /api/me': () =>
        apiUp ? { status: 401, body: apiError('unauthorized', 'Please log in.') } : { status: 502 },
    })
    renderWithStore(<App />)
    expect(await screen.findByText(/Couldn't reach the server/)).toBeInTheDocument()

    apiUp = true
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByRole('heading', { name: 'Log in' })).toBeInTheDocument()
  })

  it('goes back to the login page after logging out', async () => {
    let loggedIn = true
    fakeApi({
      'GET /api/me': () =>
        loggedIn
          ? { status: 200, body: alice }
          : { status: 401, body: apiError('unauthorized', 'Please log in.') },
      'GET /api/accounts': () => ({ status: 200, body: accounts }),
      'POST /api/logout': () => {
        loggedIn = false
        return { status: 204 }
      },
    })
    renderWithStore(<App />)
    await userEvent.click(await screen.findByRole('button', { name: 'Log out' }))
    expect(await screen.findByRole('heading', { name: 'Log in' })).toBeInTheDocument()
  })
})
