#!/usr/bin/env raku
# A long query with a live progress bar, and Ctrl-C-style cancellation.
#
#   raku -Ilib examples/progress.raku [host] [port]
use lib $*PROGRAM.IO.parent(2).add('lib');
use ClickHouse;
use ClickHouse::Progress;

my $ch = ClickHouse.new(
    host => (@*ARGS[0] // 'localhost'),
    port => (@*ARGS[1] // 8123).Int,
);

die "server is not answering /ping" unless $ch.ping;

my $bar = ClickHouse::ProgressBar.new;
say 'Scanning 4 billion rows — the bar below is live server progress.';

my $r = $ch.query('SELECT count() FROM numbers(4000000000) WHERE number % 7 = 0',
                  on-progress => $bar);
$bar.clear;

say "result : {$r.rows[0][0]}";
say "read   : {fmt-count($r.summary.read-rows)} rows, {fmt-bytes($r.summary.read-bytes)}";
say "elapsed: {$r.summary.elapsed.round(0.01)}s";

# Same query, abandoned after two seconds.
say '';
say 'Now the same scan, cancelled after 2 seconds:';
my $bar2 = ClickHouse::ProgressBar.new;
try {
    $ch.query('SELECT count() FROM numbers(400000000000) WHERE number % 7 = 0',
              on-progress => -> $p { $bar2($p); $p.cancel if $p.elapsed > 2 });
    CATCH {
        when X::ClickHouse::Cancelled {
            $bar2.clear;
            say "cancelled — query_id {.query-id} is no longer running server-side";
        }
    }
}
