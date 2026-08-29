# ClickHouse

A type-aware [ClickHouse](https://clickhouse.com) client for Raku, speaking the
HTTP interface — with live query progress, cancellation, streaming results, and
lossless handling of the types that usually go wrong.

Depends only on `JSON::Fast`.

```raku
use ClickHouse;

my $ch = ClickHouse.new(host => 'localhost', database => 'metrics');

my $r = $ch.query('SELECT country, count() AS hits FROM events GROUP BY country');
say "{.<country>}: {.<hits>}" for $r.hashes;
```

## Installing

```
zef install ClickHouse
```

Requires ClickHouse 23.6 or newer for the default `session_timezone=UTC`
behaviour; pass `timezone => ''` to work with older servers.

## Progress

`clickhouse-client` shows a progress bar while a query runs. So does this, and
for the same reason: ClickHouse reports cumulative counters roughly every
100 ms. Pass a `ClickHouse::ProgressBar` and you get one:

```raku
use ClickHouse;
use ClickHouse::Progress;

$ch.query('SELECT count() FROM huge_table WHERE ...',
          on-progress => ClickHouse::ProgressBar.new);
```

```
  ━━━━━━━━━━━━━━━━━━             62.5%  1.25B rows  10.00 GB  1.45B rows/s
```

The bar writes to stderr, so it never contaminates piped output, and it stays
silent when stderr is not a terminal — cron jobs and test runs are not filled
with escape codes.

For anything else, handle the snapshots yourself:

```raku
$ch.query($sql, on-progress => -> $p {
    note sprintf '%.1f%% — %d of %d rows, %.1fs',
        ($p.fraction // 0) * 100, $p.read-rows, $p.total-rows, $p.elapsed;
});
```

A `ClickHouse::Progress` carries `read-rows`, `read-bytes`, `total-rows`,
`written-rows`, `elapsed-ns` and `memory-usage`, plus derived `fraction`,
`elapsed` and `rows-per-second`. `fraction` is `Nil` when the server cannot
estimate a total, which happens more often than you would like — handle it.

`execute()` and `insert()` report progress too. They have no result body to
interleave records into, so those counters arrive as repeated
`X-ClickHouse-Progress` headers instead; from your side it looks the same.

## Cancelling a query

Call `.cancel` on a progress snapshot. The driver issues `KILL QUERY` on a
separate connection and throws, with whatever rows had already arrived:

```raku
my $result = try $ch.query('SELECT ... FROM enormous', on-progress => -> $p {
    $p.cancel if $p.elapsed > 30;
});
if $! ~~ X::ClickHouse::Cancelled {
    say "gave up after {$!.partial.elems} rows (query_id {$!.query-id})";
}
```

## Parameters

Placeholders are bound server-side. There is no string interpolation anywhere
in this driver, so there is nothing for a quote to escape out of:

```raku
$ch.query('SELECT * FROM users WHERE id = {id:UInt64} AND name = {n:String}',
          params => { id => 42, n => "o'brien" });
```

## Types

Values are coerced using the type strings the server sends with the data, not
guessed from their JSON shape:

| ClickHouse | Raku |
|---|---|
| `Int8` … `Int256`, `UInt8` … `UInt256` | `Int` (arbitrary precision) |
| `Float32`, `Float64` | `Num` |
| `Decimal(P, S)` | `FatRat` (exact) |
| `Bool` | `Bool` |
| `Date`, `Date32` | `Date` |
| `DateTime`, `DateTime64` | `DateTime` (UTC) |
| `Nullable(T)` | `Nil`, or the coerced `T` |
| `Array(T)` | `Array` of coerced `T` |
| `LowCardinality(T)` | as `T` |
| `String`, `UUID`, `Enum`, `IPv4`/`IPv6`, `Map`, `Tuple`, `JSON` | `Str` or the decoded JSON structure |

Two decisions worth knowing about:

**Decimals are exact.** The driver sets `output_format_json_quote_decimals=1` so
they arrive as strings, and parses them with `FatRat`. Unquoted, a
`Decimal(38, 26)` is already mangled by the JSON parser before any Raku code can
intervene; and `.Rat` caps its denominator at 64 bits, which goes silently wrong
past about 19 significant digits.

**A column with its own timezone comes back as a string.** For
`DateTime('Europe/London')` the server renders values in that zone regardless of
the session setting, and core Raku has no timezone database to map the name to
an offset. Returning a `DateTime` mislabelled as UTC would be worse than
returning the text, so you get the text.

## Inserting

```raku
$ch.insert('events', [
    [1, 'click', DateTime.now, 0.25],
    [2, 'view',  DateTime.now, 1/3],
], columns => <id kind at weight>);
```

Rows are encoded by the same code that encodes query parameters, and sent in
batches (`batch-size`, default 10 000) so a large load does not have to fit in
memory as one string.

## Large result sets

`query()` materialises every row. When that will not fit, use `each()`, which
hands you rows as they arrive and keeps memory flat:

```raku
my $summary = $ch.each('SELECT id, payload FROM enormous', -> @row {
    process(@row);
});
say "{$summary.summary.read-rows} rows read";
```

## Errors

| Class | Meaning |
|---|---|
| `X::ClickHouse` | the server rejected the query; `.code` is the ClickHouse exception code |
| `X::ClickHouse::Connection` | never got a verdict — DNS, refused, reset, TLS, truncated |
| `X::ClickHouse::Timeout` | the client-side `timeout` elapsed; `.query-id` says what to kill |
| `X::ClickHouse::Cancelled` | an `on-progress` handler called `.cancel`; `.partial` holds the rows so far |
| `X::ClickHouse::Usage` | the driver was called wrongly; nothing was sent |

A query that fails **after** ClickHouse has begun streaming — a memory limit hit
half way through a scan is the usual way — cannot be reported as an HTTP error,
because the 200 has already gone out. The server appends a tagged exception
envelope to the body instead. This driver detects that envelope and raises the
real `X::ClickHouse`, with the real code, rather than letting a JSON parse error
surface in its place.

## Connection options

```raku
ClickHouse.new(
    host     => 'localhost',
    port     => 8123,
    user     => 'default',
    password => '',
    database => 'default',
    scheme   => 'http',        # https needs IO::Socket::Async::SSL
    timezone => 'UTC',         # sent as session_timezone; '' to disable
    readonly => False,         # True sends readonly=2 on every request
    timeout  => 30,            # seconds; undefined means no client-side bound
    settings => { max_threads => 8 },
    on-progress => ClickHouse::ProgressBar.new,   # default for every call
);
```

For `https`, `tls-config` is passed straight through to
`IO::Socket::Async::SSL.connect`:

```raku
ClickHouse.new(
    host   => 'clickhouse.example.com', port => 8443, scheme => 'https',
    user   => 'reporting', password => %*ENV<CH_PASSWORD>,
    tls-config => { ca-file => '/etc/ssl/certs/ca.pem' },
);
```

A `ClickHouse` handle holds one connection and runs one query at a time. Give
each thread its own handle rather than sharing one.

`readonly => True` gives you a handle that cannot mutate data — useful for the
connection your reporting code holds.

## Why its own HTTP client

The driver needs the response body delivered line by line *while the query is
still running*, so `{"progress":...}` records can drive a bar. That rules out
any client whose only interface is "await the whole body". Speaking the one
POST that ClickHouse needs is cheaper than depending on a stack that speaks all
of HTTP — and it keeps the dependency list at `JSON::Fast`, so the module
installs on Rakudo versions that a larger stack no longer supports.

TLS is the exception: `https` requires `IO::Socket::Async::SSL`, loaded only if
you ask for it.

## Not yet

- The native protocol on port 9000. It buys live `ProfileEvents` and server-side
  log streaming, and lower per-query overhead. It does not buy progress, which
  is why it is not the priority. It would arrive as
  `ClickHouse.new(:transport<native>)`, behind this same API.
- HTTP response compression.
- Sessions (`session_id`) for temporary tables and persistent `SET`.
- A lazy `Seq` interface alongside `each()`.

## Testing

Unit tests need nothing. Integration tests need a server:

```
zef test .
CLICKHOUSE_TEST_HOST=localhost zef test .
```

`CLICKHOUSE_TEST_PORT`, `_USER`, `_PASSWORD` and `_DATABASE` are honoured too.

## License

Artistic License 2.0. See `LICENSE`.
