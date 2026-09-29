-- Runs once, the first time the Postgres container starts with an empty
-- data volume. The main database ("ledger") is created by the image itself
-- from POSTGRES_DB; this adds a second one for the test suite, which wipes
-- its tables between tests.
CREATE DATABASE ledger_test OWNER ledger;
