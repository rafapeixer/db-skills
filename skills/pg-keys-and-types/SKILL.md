---
name: pg-keys-and-types
description: Use when creating or reviewing PostgreSQL tables, columns or migrations that choose a primary key or a column type. Covers bigint identity vs serial, uuidv7 vs random UUID keys, timestamptz, text with CHECK instead of varchar(n), numeric for money, NOT NULL, CHECK and foreign key constraints, and when jsonb is the right type.
metadata:
  verified: 2026-10-18
---

# Keys and column types

## The decision

Every `CREATE TABLE` picks a key and a type for each column, and those choices are the hardest to change later: changing a column's type normally rewrites the whole table and its indexes under an `ACCESS EXCLUSIVE` lock. Get them wrong and the cost shows up months later: an `integer` key that stops at 2147483647, a random UUID index that is 39% larger than it needs to be, timestamps that are off by the writer's time zone, totals that do not add up, and rows the application cannot use because nothing stopped them. This skill fixes the default for keys, times, strings, money, nullability, constraints and JSON.

## The rule

1. Make surrogate primary keys `bigint GENERATED ALWAYS AS IDENTITY`, never `serial` or `integer`.
2. When the key must be a UUID, default it to `uuidv7()` (PG 18+; below 18, generate UUIDv7 in the application), never `gen_random_uuid()`.
3. Store points in time as `timestamptz`, never `timestamp` without time zone.
4. Use `text` with a named `CHECK (char_length(col) BETWEEN m AND n)` instead of `varchar(n)` or `char(n)`.
5. Store money as `numeric(p, s)` (or `bigint` minor units), never `real`, `double precision` or `money`.
6. Declare every column `NOT NULL` unless "unknown" is a real state, enforce value rules with `CHECK`, every reference with a `FOREIGN KEY`, and index every referencing column.
7. Use `jsonb` (never `json`) only for attributes with no fixed shape, and promote any key you filter, join, sort, or constrain to a typed column.

## Why

**Rule 1.** `serial` is "not a true type", only shorthand for an `integer` column with a separate sequence as its default, and its range is "1 to 2147483647"; the docs say to use `bigserial` "if you anticipate the use of more than 2^31 identifiers over the lifetime of the table" ([numeric types](https://www.postgresql.org/docs/18/datatype-numeric.html)). The bad example sets the sequence to that maximum and the next insert fails with SQLSTATE `2200H`. Moving to `bigint` afterwards is a type change, which "will normally cause the entire table and its indexes to be rewritten" ([ALTER TABLE](https://www.postgresql.org/docs/18/sql-altertable.html)). `bigint` costs 4 more bytes per row and never runs out. `GENERATED ALWAYS AS IDENTITY` is the SQL-standard form, and it accepts a user-supplied value "only if the INSERT statement specifies OVERRIDING SYSTEM VALUE" ([identity columns](https://www.postgresql.org/docs/18/ddl-identity-columns.html)). The good example gets `428C9` for a hand-written id. With `serial`, the bad example's import of ids 1 and 2 goes in quietly, and the next normal insert fails with `23505` because the sequence never saw them.

**Rule 2.** A B-tree fills leaf pages to its fillfactor (90 by default) "when extending the index at the right (adding new largest key values)". Pages that become completely full "will be split, leading to fragmentation" ([CREATE INDEX](https://www.postgresql.org/docs/18/sql-createindex.html)). `gen_random_uuid()` (and its PG 18 alias `uuidv4()`) is "random", while `uuidv7()` is "time-ordered" ([UUID functions](https://www.postgresql.org/docs/18/functions-uuid.html)). The PostgreSQL 18 release describes it as giving "better indexing and read performance for UUIDs" ([PostgreSQL 18 released](https://www.postgresql.org/about/news/postgresql-18-released-3142/)). Measured in this skill's examples with 200000 rows: random UUIDs leave leaf pages about 65% full and an 8.7 MB primary key. The same keys inserted in order give 90% and 6.3 MB, the same as `uuidv7()` on PG 18. Random keys also spread every insert over the whole index, so the working set is the whole index rather than its right edge. Keep `bigint` when the id never leaves your system. It is 8 bytes against 16, and the `bigint` index was 4.5 MB.

**Rule 3.** For `timestamp` without time zone, "PostgreSQL will silently ignore any time zone indication". For `timestamptz`, "the value is stored internally as UTC" and is converted to the session's `TimeZone` on output ([date/time types](https://www.postgresql.org/docs/18/datatype-datetime.html)). In the bad example, 09:00 in São Paulo and 21:00 in Tokyo are the same instant but are stored 12 hours apart. In the good example they are one value, `12:00+00`. `timestamptz` is 8 bytes, the same as `timestamp`.

**Rule 4.** "There is no performance difference" among `text`, `varchar(n)` and `varchar`, and `char(n)` "is usually the slowest of the three because of its additional storage costs" ([character types](https://www.postgresql.org/docs/18/datatype-character.html)). `varchar(n)` enforces only a maximum. It still stores `''`, and an explicit cast "will be truncated to n characters without raising an error", which the bad example shows by cutting an email to 20 characters. A `CHECK` states the real rule (minimum and maximum) and fails loudly. Changing it is cheap: drop and add the constraint `NOT VALID`, then `VALIDATE CONSTRAINT`, which takes only `SHARE UPDATE EXCLUSIVE` ([ALTER TABLE](https://www.postgresql.org/docs/18/sql-altertable.html)). The good example keeps the same file node. Shrinking a `varchar` limit in the bad example wrote a new copy of the table.

**Rule 5.** `numeric` "is especially recommended for storing monetary amounts and other quantities where exactness is required", while `real` and `double precision` "are inexact" ([numeric types](https://www.postgresql.org/docs/18/datatype-numeric.html)). Ten orders of 0.10 sum to exactly `1.00` in `numeric` and to `0.9999999999999999` in `double precision`. The `money` type's fractional precision "is determined by the database's lc_monetary setting", and loading a dump into a database with a different `lc_monetary` "might not work" ([monetary types](https://www.postgresql.org/docs/18/datatype-money.html)).

**Rule 6.** The docs advise that "in most database designs the majority of columns should be marked not null" ([constraints](https://www.postgresql.org/docs/18/ddl-constraints.html)). A nullable `total` drops out of both `total >= 0` and `total < 0`, so reports silently miss rows. A `CHECK` "is satisfied if the check expression evaluates to true or the null value", so a `CHECK` without `NOT NULL` lets `NULL` through (same page). Without `REFERENCES`, the bad example stores an order for customer 999, who does not exist. Declaring a foreign key "does not automatically create an index on the referencing columns", and without one a `DELETE` on the parent "will require a scan of the referencing table" (same page).

**Rule 7.** `json` "stores an exact copy of the input text, which processing functions must reparse on each execution" and keeps duplicate keys. `jsonb` keeps only the last duplicate, supports indexing, and "most applications should prefer" it ([JSON types](https://www.postgresql.org/docs/18/datatype-json.html)). The bad example also shows that `json` has no `=` operator (`42883`). Neither type gives you types, `NOT NULL` or foreign keys inside the document: the bad example's `"total": "abc"` is accepted, while the typed `numeric` column refuses it (`22P02`). Any update "acquires a row-level lock on the whole row", so keep documents small and atomic (same page).

## Good example

See [`examples/good/test.sql`](examples/good/test.sql).

```sql
CREATE TABLE orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status text NOT NULL CHECK (status IN ('pending', 'paid', 'shipped')),
  total numeric(12, 2) NOT NULL CHECK (total >= 0),
  placed_at timestamptz NOT NULL,
  attributes jsonb NOT NULL DEFAULT '{}'
);
-- Declaring the FK does not create this index; deletes on customers need it.
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
```

```sql
-- PG 18+: a time-ordered UUID key behaves like bigint identity.
EXECUTE 'CREATE TABLE devices (id uuid PRIMARY KEY DEFAULT uuidv7(), name text NOT NULL)';
```

The test asserts that:

- an explicit id is refused (`428C9`), and so are a `NULL` total (`23502`), a negative total, a misspelled status, an empty or 300-character email (`23514`), an unknown customer (`23503`), and a non-numeric total (`22P02`);
- 09:00 in São Paulo and 21:00 in Tokyo are stored as one instant, 12:00 UTC;
- ten totals of 0.10 sum to exactly 1.00;
- raising the email length limit through a `NOT VALID` `CHECK` keeps the same table file;
- `jsonb` keeps the last duplicate key and compares documents with `=`;
- `orders.customer_id` has its own index;
- 200000 `bigint` identity keys, and on PG 18 200000 `uuidv7()` keys, fill leaf pages to at least 85%. On PG 15 the `uuidv7()` part is skipped with a notice.

## Bad example

See [`examples/bad/test.sql`](examples/bad/test.sql).

```sql
-- MISTAKE: serial is a 4-byte integer with a separate sequence; it runs out at 2147483647
-- and does not notice ids written by hand.
CREATE TABLE customers (
  id serial PRIMARY KEY,
  -- MISTAKE: varchar(20) is a guess at a business rule; it still accepts '' and casts truncate silently.
  email varchar(20),
  -- MISTAKE: timestamp without time zone stores wall-clock time and drops the offset.
  created_at timestamp DEFAULT now()
);

CREATE TABLE orders (
  -- MISTAKE: random UUIDv4 keys land on random leaf pages and split them half full.
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- MISTAKE: no REFERENCES and no NOT NULL; orphans and missing values get in.
  customer_id integer,
  status varchar(10),
  -- MISTAKE: double precision cannot represent 0.10 exactly.
  total double precision,
  placed_at timestamp,
  -- MISTAKE: json keeps duplicate keys, reparses on every read and has no = operator.
  details json
);
```

This is the schema written from habit or copied from another database. The assertions show the costs:

- the `serial` key collides with hand-inserted ids (`23505`) and stops at 2147483647 (`2200H`);
- `varchar(20)` stores `''`, a cast silently truncates an email, and shrinking the limit rewrites the table;
- `timestamp` stores the same instant 12 hours apart;
- `double precision` sums ten 0.10 to less than 1;
- a `NULL` total drops out of both halves of a report, and an order for a missing customer is stored;
- `json` keeps both copies of a duplicate key, accepts `"total": "abc"` and cannot be compared;
- the same 200000 UUIDs give a primary key under 75% leaf density and over 30% larger when inserted in random order than when inserted in key order.

## Checklist

When reviewing schema or SQL under this skill, confirm:

- [ ] Every surrogate key is `bigint GENERATED ALWAYS AS IDENTITY` (or `BY DEFAULT` only where imports must keep ids), with no `serial`, `integer` or `smallint` keys.
- [ ] Every UUID key defaults to `uuidv7()` on PG 18+, or is generated as UUIDv7 by the application below 18, never `gen_random_uuid()`.
- [ ] No column has type `timestamp` without time zone, except a wall-clock value that is deliberately zone-free.
- [ ] No column is `varchar(n)` or `char(n)`; length rules are named `CHECK` constraints on `text`.
- [ ] Every money column is `numeric(p, s)` or an integer of minor units, and none is `real`, `double precision` or `money`.
- [ ] Every nullable column has a written reason why "unknown" is a valid state.
- [ ] Every column that holds another table's id has a `FOREIGN KEY` and an index that starts with that column.
- [ ] Every enumerated or ranged value (status, quantity, percentage) has a `CHECK`.
- [ ] No column is `json`, and no `jsonb` key is used in `WHERE`, `JOIN`, `ORDER BY` or a uniqueness rule without being promoted to a typed column.

## When not to apply

- **Identifiers created outside the database.** When clients, other services or offline devices create ids before insert, use a UUID key generated as UUIDv7 by whoever creates it. Keep `GENERATED BY DEFAULT AS IDENTITY` for tables whose ids an import or a replication tool must preserve.
- **Ids that must not reveal order or creation time.** A UUIDv7 contains its creation time, and `uuid_extract_timestamp()` returns it ([UUID functions](https://www.postgresql.org/docs/18/functions-uuid.html)). If a public id must not leak when or in what order rows were created, expose a random token in a separate unique column and keep the ordered key internal.
- **Wall-clock values that are not instants.** A store's opening time, or a recurring "09:00 local" alarm, is a `time` or `timestamp` plus a separate time zone column, because the instant changes with the zone's rules.
- **Fixed-length codes defined by a standard.** An ISO 4217 currency code or country code can be `text` with `CHECK (col ~ '^[A-Z]{3}$')`. The regular expression states the rule more precisely than `char(3)`.
- **Extremely high-volume measurements.** Sensor readings or metrics where small rounding errors are acceptable may use `double precision` for speed and size. That never applies to amounts that are billed or reconciled.
- **Truly optional data and staging tables.** A column filled in later in a workflow (`shipped_at`) is nullable by design. A raw import table can be loose, as long as the copy into the real table applies every constraint.
- **Payloads stored as received.** A webhook body kept for audit can be `jsonb` (or `json` if you must keep key order and duplicates byte for byte), as long as no business logic queries inside it.
