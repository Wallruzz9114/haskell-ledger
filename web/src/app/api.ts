import {
  createApi,
  fetchBaseQuery,
  type BaseQueryFn,
  type FetchArgs,
  type FetchBaseQueryError,
} from '@reduxjs/toolkit/query/react'
// The API's types are generated from the Haskell code (backend/src/Ledger/Api.hs),
// so they can't drift from what the server really sends. The short names
// below are what the rest of the app uses.
import type {
  AccountView,
  DashboardView,
  DepositRequest,
  Entry as ApiEntry,
  ErrorBody,
  LoginRequest,
  OpenAccountRequest,
  Transfer as ApiTransfer,
  TransactionsPageView,
  TransferRequestBody,
  UserView,
} from './generated/apiTypes'

export type {
  AccountKind,
  BalancePointView,
  DashboardView,
  PartyView,
  Role,
  TransactionView,
} from './generated/apiTypes'

/** What the transactions page filters by. */
export interface TransactionFilter {
  q: string
  account: string
}
export type Account = AccountView
export type User = UserView
export type Entry = ApiEntry
export type Transfer = ApiTransfer
/** Every error from the Haskell API has this shape, e.g. insufficient_funds. */
export type ApiError = ErrorBody

/** A transfer request plus the Idempotency-Key header it's sent with. */
export type TransferInput = TransferRequestBody & { idempotencyKey: string }

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
  // Balances can change while you're looking elsewhere (someone pays you,
  // or you move money in another tab). Refetch whatever is on screen when
  // the tab gets focus again or the network comes back, so the page never
  // shows a stale balance for long. Needs setupListeners (see main.tsx).
  refetchOnFocus: true,
  refetchOnReconnect: true,
  endpoints: (build) => ({
    me: build.query<User, void>({
      query: () => 'me',
      providesTags: ['Me'],
    }),
    login: build.mutation<User, LoginRequest>({
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
    /** The dashboard for one month ("2026-09"), or this month if omitted. */
    dashboard: build.query<DashboardView, string | undefined>({
      query: (month) => (month ? `dashboard?month=${encodeURIComponent(month)}` : 'dashboard'),
      providesTags: ['Account'],
    }),
    /**
     * Transactions, 25 at a time. An "infinite query" keeps every page loaded
     * so far and knows how to ask for the next one: the page param is the
     * cursor the API sent with the previous page (null for the first page).
     */
    transactions: build.infiniteQuery<TransactionsPageView, TransactionFilter, string | null>({
      infiniteQueryOptions: {
        initialPageParam: null,
        // undefined means "no more pages".
        getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined,
      },
      query: ({ queryArg, pageParam }) => ({
        url: 'transactions',
        params: {
          limit: 25,
          ...(queryArg.q ? { q: queryArg.q } : {}),
          ...(queryArg.account ? { account: queryArg.account } : {}),
          ...(pageParam ? { before: pageParam } : {}),
        },
      }),
      providesTags: ['Account'],
    }),
    accountEntries: build.query<Entry[], string>({
      query: (id) => `accounts/${encodeURIComponent(id)}/entries`,
      providesTags: ['Account'],
    }),
    openAccount: build.mutation<Account, OpenAccountRequest>({
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
    deposit: build.mutation<Transfer, DepositRequest & { idempotencyKey: string }>({
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
  useDashboardQuery,
  useTransactionsInfiniteQuery,
  useOpenAccountMutation,
  useSetOwnerMutation,
  useDepositMutation,
  useTransferMutation,
} = ledgerApi

/** Is this RTK Query error a 401 (not logged in)? */
export function isUnauthorized(err: unknown): boolean {
  return typeof err === 'object' && err !== null && 'status' in err && err.status === 401
}

/**
 * Pull the human-readable message out of an RTK Query error. Unexpected
 * failures carry a request id, shown as a reference that matches the
 * server's log line.
 */
export function errorMessage(err: unknown): string | null {
  if (!err) return null
  if (typeof err === 'object' && err !== null && 'data' in err) {
    const data = (err as { data: unknown }).data
    if (data && typeof data === 'object' && 'message' in data) {
      const { message, requestId } = data as ApiError
      return requestId ? `${message} (reference ${requestId})` : message
    }
  }
  return "Couldn't reach the server. Check that the API is running, then try again."
}
