use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse;
use ClickHouse::Progress;

# Integration tests need a live server, which ecosystem CI does not have.
# Point CLICKHOUSE_TEST_HOST at one to run them:
#   CLICKHOUSE_TEST_HOST=localhost zef test .
my $host = %*ENV<CLICKHOUSE_TEST_HOST>;
without $host {
    plan :skip-all('set CLICKHOUSE_TEST_HOST to run integration tests');
    exit 0;
}

my $ch = ClickHouse.new(
    host     => $host,
    port     => (%*ENV<CLICKHOUSE_TEST_PORT> // 8123).Int,
    user     => (%*ENV<CLICKHOUSE_TEST_USER> // 'default'),
    password => (%*ENV<CLICKHOUSE_TEST_PASSWORD> // ''),
    database => (%*ENV<CLICKHOUSE_TEST_DATABASE> // 'default'),
);

plan 35;

ok $ch.ping, 'server answers /ping';

# --- basics -----------------------------------------------------------------
my $r = $ch.query('SELECT 1 AS a, {n:String} AS b', params => { n => "o'brien" });
is-deeply $r.names.Array, [<a b>],          'column names';
is-deeply $r.rows[0].Array, [1, "o'brien"], 'row values, parameter bound server-side';
is $r.hashes[0]<b>, "o'brien",              'hashes keyed by column name';
ok $r.query-id.chars,                       'a query id was assigned';
ok $r.summary.defined,                      'summary counters came back';

# A parameter is data, never SQL: this must come back as a string, not run.
my $inj = $ch.query('SELECT {x:String} AS v', params => { x => "'; DROP TABLE nope; --" });
is $inj.rows[0][0], "'; DROP TABLE nope; --", 'quotes in a parameter cannot break out';

# --- lossless types ---------------------------------------------------------
my %t = $ch.query(q{SELECT
    toDecimal128('0.33333333333333333333333333', 26) AS d,
    toUInt64(18446744073709551615)                  AS u,
    toInt64(-9223372036854775808)                   AS i,
    toDateTime('2026-08-18 18:32:52')               AS dt,
    toDate('2026-08-18')                            AS dd,
    [1, 2, 3]                                       AS arr,
    CAST(NULL AS Nullable(Int32))                   AS nn}).hashes[0];

is %t<d>.Str, '0.33333333333333333333333333', 'Decimal128 survives the round trip';
is %t<u>, 18446744073709551615,               'UInt64 max';
is %t<i>, -9223372036854775808,               'Int64 min';
is %t<dt>, DateTime.new('2026-08-18T18:32:52Z'), 'DateTime in UTC';
is %t<dd>, Date.new('2026-08-18'),            'Date';
is-deeply %t<arr>.Array, [1, 2, 3],           'Array';
nok %t<nn>.defined,                           'NULL is undefined';

# --- progress ---------------------------------------------------------------
my @snaps;
$ch.query('SELECT sum(number) FROM numbers(1500000000)', on-progress => -> $p { @snaps.push: $p });
ok @snaps >= 2,                               'progress fired more than once mid-query';
ok ([<=] @snaps.map(*.read-rows)),            'progress counters are cumulative';
ok @snaps[*-1].fraction > 0.5,                'progress reaches a meaningful fraction';
ok @snaps[*-1].rows-per-second > 0,           'throughput is derivable';

# X-ClickHouse-Summary is flushed with the early header block, so on its own it
# describes the query's first few hundred milliseconds. The summary must
# describe the whole scan.
my $big = $ch.query('SELECT count() FROM numbers(1500000000)');
ok $big.summary.read-rows >= 1_500_000_000,   'summary counts the whole scan';
ok $big.summary.final,                        'summary is marked final';

# --- errors -----------------------------------------------------------------
my $bad = try { $ch.query('SELECT nonexistent_fn(1)'); Nil } // $!;
isa-ok $bad, X::ClickHouse,                   'a rejected query throws X::ClickHouse';
is $bad.code, 46,                             'UNKNOWN_FUNCTION code';
ok $bad.message.contains('Function with name'), 'server message is preserved';

# The hard case: failure after streaming has begun, where the server has
# already committed to HTTP 200 and reports the error in the body instead.
my $mid = try {
    $ch.query("SELECT throwIf(number = 500000, 'boom') AS x FROM numbers(2000000)"); Nil
} // $!;
isa-ok $mid, X::ClickHouse,                   'mid-stream failure throws X::ClickHouse';
is $mid.code, 395,                            'mid-stream failure carries its real code';
ok $mid.message.contains('boom'),             'mid-stream failure carries its real message';

# --- cancellation -----------------------------------------------------------
my $t0 = now;
my $cancelled = try {
    $ch.query('SELECT sum(number) FROM numbers(200000000000)',
              on-progress => -> $p { $p.cancel if $p.read-rows > 100_000_000 });
    Nil
} // $!;
isa-ok $cancelled, X::ClickHouse::Cancelled,  'cancelling throws X::ClickHouse::Cancelled';
ok now - $t0 < 30,                            'cancellation actually stops the scan';
ok $ch.query('SELECT 7').rows[0][0] == 7,     'handle still works after a cancellation';

# --- insert round trip ------------------------------------------------------
my $tbl = 'raku_ch_test_' ~ (^1_000_000).pick;
$ch.execute("CREATE TABLE $tbl (id UInt64, name String, when DateTime, amt Decimal(38,20)) ENGINE = Memory");
LEAVE { try $ch.execute("DROP TABLE IF EXISTS $tbl") }

my $when = DateTime.new('2026-08-18T14:32:52-04:00');
$ch.insert($tbl, [
    [1, "o'brien\\slash", $when, '0.33333333333333333333'.FatRat],
    [2, 'plain',          $when, 1/3],
], columns => <id name when amt>);

my @back = $ch.query("SELECT id, name, when, amt FROM $tbl ORDER BY id").hashes;
is @back.elems, 2,                            'both rows landed';
is @back[0]<name>, "o'brien\\slash",          'quotes and backslashes survive INSERT';
is @back[0]<when>, $when.utc,                 'DateTime keeps its instant through INSERT';
is @back[0]<amt>.Str, '0.33333333333333333333', 'Decimal keeps its digits through INSERT';

# --- streaming --------------------------------------------------------------
my $n = 0;
my $streamed = $ch.each('SELECT number FROM numbers(100000)', -> @row { $n++ });
is $n, 100000,                                'each() sees every row';
is $streamed.rows.elems, 0,                   'each() does not materialise rows';
