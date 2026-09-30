// Generated from the Haskell types in backend/src/Ledger/Api.hs.
// Do not edit by hand: run `cabal run -v0 ledger-typescript > web/src/app/generated/apiTypes.ts`
// from the repository root. A backend test fails if this file is out of date.

export type AccountView = IAccountView;

export interface IAccountView {
  id: string;
  name: string;
  kind: AccountKind;
  owner: string | null;
  balanceCents: number;
}

export type AccountKind = "Customer" | "External";

export type UserView = IUserView;

export interface IUserView {
  username: string;
  role: Role;
}

export type Role = "customer" | "admin";

export type Entry = IEntry;

export interface IEntry {
  transfer: number;
  account: string;
  amount: number;
  counterparty: string;
  memo: string;
  createdAt: string;
}

export type Transfer = ITransfer;

export interface ITransfer {
  id: number;
  from: string;
  to: string;
  amount: number;
  memo: string;
  createdAt: string;
}

export type ErrorBody = IErrorBody;

export interface IErrorBody {
  error: string;
  message: string;
}

export type DashboardView = IDashboardView;

export interface IDashboardView {
  totalBalanceCents: number;
  month: string;
  series: BalancePointView[];
  moneyInCents: number;
  moneyOutCents: number;
  topSources: PartyView[];
  topSpending: PartyView[];
}

export type BalancePointView = IBalancePointView;

export interface IBalancePointView {
  date: string;
  balanceCents: number;
}

export type PartyView = IPartyView;

export interface IPartyView {
  account: string;
  name: string;
  amountCents: number;
}

export type TransactionsPageView = ITransactionsPageView;

export interface ITransactionsPageView {
  items: TransactionView[];
  nextCursor: string | null;
}

export type TransactionView = ITransactionView;

export interface ITransactionView {
  transfer: number;
  account: string;
  accountName: string;
  counterparty: string;
  counterpartyName: string;
  amountCents: number;
  memo: string;
  createdAt: string;
}

export type LoginRequest = ILoginRequest;

export interface ILoginRequest {
  username: string;
  password: string;
}

export type OpenAccountRequest = IOpenAccountRequest;

export interface IOpenAccountRequest {
  id: string;
  name: string;
  owner?: string;
}

export type SetOwnerRequest = ISetOwnerRequest;

export interface ISetOwnerRequest {
  owner: string;
}

export type TransferRequestBody = ITransferRequestBody;

export interface ITransferRequestBody {
  from: string;
  to: string;
  amountCents: number;
  memo?: string;
}

export type DepositRequest = IDepositRequest;

export interface IDepositRequest {
  to: string;
  amountCents: number;
}