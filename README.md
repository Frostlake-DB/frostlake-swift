# frostlake-swift

A zero-dependency Swift driver for [Frostlake](https://github.com/Frostlake-DB), speaking the
engine's HTTP protocol against a running `DatabaseHttpServer`. Pure SwiftPM, no third-party
packages — Foundation provides the HTTP transport and the JSON is parsed by the driver itself so
`NUMBER(38, …)` values keep **all 38 digits**. Swift 6 language mode, strict-concurrency clean,
async/await API.

```swift
import Frostlake

let conn = try await connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")
let result = try await conn.execute("SELECT id, name FROM people WHERE id = ?", [1])
for row in result.rows {
    print(row["ID"]!, row["NAME"]!)
}
```

## Requirements

- Swift 6.0+ (Linux or macOS 13+)
- A Frostlake engine ≥ 0.0.7 serving its HTTP API (`DatabaseHttpServer`)

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Frostlake-DB/frostlake-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Frostlake", package: "frostlake-swift")]),
]
```

## DSN

```
frostlake://host[:port]/[database][?schema=name]
http://host[:port]/[database][?schema=name]
```

`frostlake://` without an explicit port means the server default, **18082**; an `http://` DSN keeps
URL port semantics. The database and schema are applied with `USE DATABASE` / `USE SCHEMA` before
the connection's first statement — bare when they are valid unquoted identifiers (the engine
uppercases them, like Snowflake), quoted with exact case otherwise. A failed USE stays queued, so
every later statement keeps failing instead of silently running against the server's default
database.

## API

- `connect(_ dsn: String) async throws -> FrostlakeConnection` — parse the DSN and verify the
  server responds on `/api/health`.
- `FrostlakeConnection` (an actor):
  - `execute(_ sql: String, _ binds: [FrostlakeBind] = [], multiStatementCount: Int? = nil)
    async throws -> FrostlakeResult`
  - `begin()` / `commit()` / `rollback()` — `begin` turns autocommit off; commit/rollback turn it
    back on
  - `setAutoCommit(_:)`, `autoCommit`, `sessionId`, `isClosed`, `ping()`, `close()`
- `FrostlakeResult` — `resultSets` (one per statement; SQL holding several answers with several, once
  the session has asked for them with `ALTER SESSION SET MULTI_STATEMENT_COUNT = n`, or `0` for any
  number), with the first surfaced as `columns` / `rows` / `rowCount` / `updateCount`, plus
  `executionTimeMs`.
- `FrostlakeRow` — `row[0]` by position, `row["NAME"]` by name (exact match first, then
  case-insensitive, so `row["name"]` finds the server-uppercased `NAME`).
- `FrostlakeValue` — `.null / .int / .decimal / .double / .bool / .string / .binary` with typed
  accessors (`intValue`, `decimalValue`, `doubleValue`, `boolValue`, `stringValue`, `binaryValue`,
  `dateValue`, `timestampValue`, `timeValue`).
- `FrostlakeError` — `.invalidDSN`, `.transport`, `.unhealthy`, `.unreadableBody`, `.sql(message)`,
  `.binds`, `.connectionClosed`.

Statements are **serialized per connection**, in call order — the session id is only learned from
the first response, so concurrent round trips would each get their own server session. Concurrent
`execute` calls on one connection are safe; they queue.

### Statement counts per call

`multiStatementCount:` declares on one call how many statements it carries, instead of asking the
session for them:

```swift
let result = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B", multiStatementCount: 2)
```

`0` means any number. The count travels with that one request and outranks the session's
`MULTI_STATEMENT_COUNT` for it, but changes no session state — nothing to save and put back, and
other statements on the connection are unaffected. Left out, nothing is sent at all and the
session's value decides, which is 1 until it is told otherwise.

## Type mapping

| Engine type | Wire form | `FrostlakeValue` |
|---|---|---|
| NUMBER(p, 0) and INT aliases | JSON number | `.int(Int64)` (engine stores integers 64-bit — lossless) |
| NUMBER(p, s > 0) | JSON number, full precision | `.decimal(Decimal)` — exact to all 38 digits |
| FLOAT / DOUBLE / REAL | JSON number | `.double(Double)` |
| BOOLEAN | JSON bool | `.bool(Bool)` |
| VARCHAR / CHAR / TEXT | JSON string | `.string(String)` |
| BINARY | bare hex text | `.binary(Data)` |
| DATE / TIME / TIMESTAMP_* | text (`2026-01-02`, `03:04:05`, `2026-01-02 03:04:05.123`, LTZ/TZ with a trailing `±HHMM`) | `.string`, parse via `dateValue` / `timeValue` / `timestampValue` |
| ARRAY / OBJECT / VARIANT | Snowflake's text rendering | `.string` (not always parseable JSON — a SQL NULL array element renders as `undefined`) |
| SQL NULL | JSON null | `.null` |

`timestampValue` reports the **wall-clock reading placed at UTC** — the same local part the JDBC
driver's `getTimestamp` reports; a trailing zone offset on a TIMESTAMP_LTZ/TZ is dropped, not
applied.

## Bind parameters

Parameters are inlined client-side (the protocol has no server-side binding) with the same literal
forms as Frostlake's JDBC driver. The `?` scanner skips string literals (backslash escapes and `''`
doubling), `"quoted"` identifiers, `--` `//` `/* */` comments, and `$$…$$` dollar-quoted strings.

`FrostlakeBind` cases: `.null`, `.bool`, `.int`, `.double`, `.decimal`, `.string` (escapes both
backslash and quote), `.timestamp(Date)` → `'…'::TIMESTAMP_NTZ` (UTC wall clock), `.date(Date)` →
`'…'::DATE`, `.binary(Data)` → `X'…'`, `.array`. Literal conformances let you write
`[1, "x", 3.14, true, nil]`.

## Affected-row counts

DML statements answer with a single row of count columns (one for INSERT/DELETE, several for MERGE
and UPDATE). That row stays in `columns` / `rows` like any other result, and `updateCount` carries
the affected-row count: an `Int64` for DML — `0` when nothing matched — and `nil` for every other
statement. `rowCount` is the affected-row count for DML and the number of rows otherwise.

An engine from 0.1.0 on reports each statement's count itself, so a query whose column merely
carries a count's name (`SELECT 9 AS "number of rows inserted"`, or a `->>` chain reading an
INSERT's status row) stays a query. Against an older engine the driver recognizes the count row by
its exact column names and sums them; that cannot tell such a query from DML. Per Snowflake
semantics, `number of multi-joined rows updated` is recognized but not part of the count.

## Tests

```sh
swift test                       # unit tests (offline)

# integration: point at a running server…
FROSTLAKE_URL=frostlake://localhost:18082 swift test

# …or let the suite spawn its own from the engine jar + dependencies:
FROSTLAKE_CLASSPATH="$(scripts/engine-classpath.sh)" swift test
```

The integration suite is verified against engine 0.0.7 and 0.1.0-SNAPSHOT.

## License

Apache-2.0 — see [LICENSE](LICENSE).
