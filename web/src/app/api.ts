import {
  createApi,
  fetchBaseQuery,
  type BaseQueryFn,
  type FetchArgs,
  type FetchBaseQueryError,
} from '@reduxjs/toolkit/query/react'

export type AccountKind = 'Customer' | 'External'
export type Role = 'customer' | 'admin'

export interface User {
  username: string
  role: Role
}

export interface Account {
  id: string
  name: string
  kind: AccountKind
  /** null for system accounts like "external". */
  owner: string | null
  balanceCents: number
}

/** One side of a transfer, as seen from one account. */
export interface Entry {
  transfer: number
  account: string
  /** Negative when money left this account, positive when it arrived. */
  amount: number
  /** The account on the other side: who paid this account, or who it paid. */
  counterparty: string
  memo: string
  /** ISO 8601 timestamp in UTC, e.g. "2026-09-29T18:05:12.345Z". */
  createdAt: string
}

export interface Transfer {
  id: number
  from: string
  to: string
  amount: number
  memo: string
  createdAt: string
}

/** Every error from the Haskell API has this shape, e.g. insufficient_funds. */
export interface ApiError {
  error: string
  message: string
}

export interface TransferInput {
  from: string
  to: string
  amountCents: number
  memo: string
  idempotencyKey: string
}

const rawBaseQuery = fetchBaseQuery({
  // An absolute URL built from the page's own origin, so the same code
  // works in the browser (via the Vite proxy) and in tests (jsdom).
  baseUrl: `${globalThis.location?.origin ?? 'http://localhost'}/api`,
  // Send the session cookie with every request.
  credentials: 'same-origin',
})

/**
 * The base query every endpoint uses. When any request comes back 401 (the
 * session expired or was ended elsewhere), re-check who is logged in, which
 * sends the app back to the login page.
 */
const baseQuery: BaseQueryFn<string | FetchArgs, unknown, FetchBaseQueryError> = async (
  args,
  api,
  extraOptions,
) => {
  const result = await rawBaseQuery(args, api, extraOptions)
  if (result.error?.status === 401 && api.endpoint !== 'me' && api.endpoint !== 'login') {
    api.dispatch(ledgerApi.util.invalidateTags(['Me']))
  }
  return result
}

/**
 * RTK Query owns all server state. Mutations invalidate the 'Account' tag,
 * so balances and entries refetch automatically after money moves.
 */
export const ledgerApi = createApi({
  reducerPath: 'ledgerApi',
  baseQuery,
  tagTypes: ['Me', 'Account'],
  endpoints: (build) => ({
    me: build.query<User, void>({
      query: () => 'me',
      providesTags: ['Me'],
    }),
    login: build.mutation<User, { username: string; password: string }>({
      query: (body) => ({ url: 'login', method: 'POST', body }),
      invalidatesTags: ['Me', 'Account'],
    }),
    logout: build.mutation<void, void>({
      query: () => ({ url: 'logout', method: 'POST' }),
      // Forget every cached response: the next user must not see them.
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        await queryFulfilled.catch(() => undefined)
        dispatch(ledgerApi.util.resetApiState())
      },
    }),
    listAccounts: build.query<Account[], void>({
      query: () => 'accounts',
      providesTags: ['Account'],
    }),
    accountEntries: build.query<Entry[], string>({
      query: (id) => `accounts/${encodeURIComponent(id)}/entries`,
      providesTags: ['Account'],
    }),
    openAccount: build.mutation<Account, { id: string; name: string; owner?: string }>({
      query: (body) => ({ url: 'accounts', method: 'POST', body }),
      invalidatesTags: ['Account'],
    }),
    setOwner: build.mutation<Account, { id: string; owner: string }>({
      query: ({ id, owner }) => ({
        url: `accounts/${encodeURIComponent(id)}/owner`,
        method: 'PUT',
        body: { owner },
      }),
      invalidatesTags: ['Account'],
    }),
    deposit: build.mutation<Transfer, { to: string; amountCents: number; idempotencyKey: string }>({
      query: ({ idempotencyKey, ...body }) => ({
        url: 'deposits',
        method: 'POST',
        body,
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
      invalidatesTags: ['Account'],
    }),
    transfer: build.mutation<Transfer, TransferInput>({
      query: ({ idempotencyKey, ...body }) => ({
        url: 'transfers',
        method: 'POST',
        body,
        headers: { 'Idempotency-Key': idempotencyKey },
      }),
      invalidatesTags: ['Account'],
    }),
  }),
})

export const {
  useMeQuery,
  useLoginMutation,
  useLogoutMutation,
  useListAccountsQuery,
  useAccountEntriesQuery,
  useOpenAccountMutation,
  useSetOwnerMutation,
  useDepositMutation,
  useTransferMutation,
} = ledgerApi

/** Is this RTK Query error a 401 (not logged in)? */
export function isUnauthorized(err: unknown): boolean {
  return typeof err === 'object' && err !== null && 'status' in err && err.status === 401
}

/** Pull the human-readable message out of an RTK Query error. */
export function errorMessage(err: unknown): string | null {
  if (!err) return null
  if (typeof err === 'object' && err !== null && 'data' in err) {
    const data = (err as { data: unknown }).data
    if (data && typeof data === 'object' && 'message' in data) {
      return (data as ApiError).message
    }
  }
  return 'Something went wrong. Is the API running on port 8080?'
}
