use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse::Progress;

plan 19;

my $p = ClickHouse::Progress.from-json({
    read_rows => '1250000000', read_bytes => '10000000000',
    total_rows_to_read => '2000000000', elapsed_ns => '860000000',
    memory_usage => '4496',
}, query-id => 'q1');

is $p.read-rows,    1250000000,        'read-rows';
is $p.total-rows,   2000000000,        'total-rows';
is $p.memory-usage, 4496,              'memory-usage';
is $p.query-id,     'q1',              'query-id carried through';
is-approx $p.fraction, 0.625,          'fraction';
is-approx $p.elapsed,  0.86,           'elapsed seconds from nanoseconds';
ok $p.rows-per-second > 1.4e9,         'rows per second';
nok $p.final,                          'in-flight snapshot is not final';

# Counters are cumulative, so a snapshot past the estimate must not report >100%.
my $over = ClickHouse::Progress.from-json({ read_rows => '30', total_rows_to_read => '20' });
is $over.fraction, 1.0,                'fraction is clamped at 1';

# ClickHouse cannot always estimate a total; a bar has to cope without one.
my $unknown = ClickHouse::Progress.from-json({ read_rows => '500', elapsed_ns => '1000000' });
nok $unknown.fraction.defined,         'no fraction without a row estimate';
is $unknown.total-rows, 0,             'total-rows is zero, not undefined';

is fmt-count(999),          '999',      'counts below 1000 are bare';
is fmt-count(1_250_000),    '1.25M',    'millions';
is fmt-count(3_000_000_000),'3.00B',    'billions';
is fmt-bytes(512),          '512 B',    'bytes';
is fmt-bytes(10_000_000_000), '10.00 GB','gigabytes';

# The bar must stay silent when stderr is not a terminal, or every cron job
# and test run fills up with escape codes.
my $quiet = ClickHouse::ProgressBar.new(out => $*OUT, enabled => False);
lives-ok { $quiet($p); $quiet.clear },  'disabled bar writes nothing and does not die';

# The bar is documented as something you hand straight to :on-progress, which
# only works if it satisfies a Callable constraint rather than merely having
# a CALL-ME method.
ok ClickHouse::ProgressBar ~~ Callable,   'ProgressBar is a Callable';
sub takes-handler(:&on-progress) { &on-progress }
lives-ok { takes-handler(on-progress => ClickHouse::ProgressBar.new) },
                                          'ProgressBar binds to an :&on-progress parameter';
