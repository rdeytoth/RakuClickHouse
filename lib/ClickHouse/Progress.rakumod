use v6.d;

#| Query progress as ClickHouse reports it, plus a terminal progress bar.
#|
#| ClickHouse emits cumulative counters roughly every 100ms while a query runs
#| — over HTTP as {"progress":...} records inside a *WithProgress format, or as
#| repeated X-ClickHouse-Progress headers. Both land here.
#| One progress snapshot. Counters are cumulative, not deltas.
class ClickHouse::Progress {
    has Int  $.read-rows     = 0;
    has Int  $.read-bytes    = 0;
    has Int  $.total-rows    = 0;   # 0 when the server cannot estimate it
    has Int  $.written-rows  = 0;
    has Int  $.written-bytes = 0;
    has Int  $.result-rows   = 0;
    has Int  $.elapsed-ns    = 0;
    has Int  $.memory-usage  = 0;
    has Str  $.query-id;
    #| True for the final X-ClickHouse-Summary snapshot rather than an
    #| in-flight update.
    has Bool $.final = False;

    has Bool $!cancel-requested = False;

    #| Ask the driver to stop this query. Call it from an on-progress handler;
    #| the driver issues KILL QUERY and throws X::ClickHouse::Cancelled.
    method cancel(--> Nil) { $!cancel-requested = True }
    method cancel-requested(--> Bool) { $!cancel-requested }

    #| 0..1, or Nil when the server reported no row estimate to divide by.
    method fraction() {
        return Nil unless $!total-rows > 0;
        min(1.0, $!read-rows / $!total-rows);
    }
    method elapsed(--> Real) { $!elapsed-ns / 1_000_000_000 }
    method rows-per-second(--> Real) {
        my $s = self.elapsed;
        $s > 0 ?? $!read-rows / $s !! 0;
    }
    method bytes-per-second(--> Real) {
        my $s = self.elapsed;
        $s > 0 ?? $!read-bytes / $s !! 0;
    }

    #| Build a snapshot from a decoded progress/summary JSON object.
    method from-json(%h, Str :$query-id, Bool :$final = False) {
        ClickHouse::Progress.new(
            read-rows     => (%h<read_rows>          // 0).Int,
            read-bytes    => (%h<read_bytes>         // 0).Int,
            total-rows    => (%h<total_rows_to_read> // 0).Int,
            written-rows  => (%h<written_rows>       // 0).Int,
            written-bytes => (%h<written_bytes>      // 0).Int,
            result-rows   => (%h<result_rows>        // 0).Int,
            elapsed-ns    => (%h<elapsed_ns>         // 0).Int,
            memory-usage  => (%h<memory_usage>       // 0).Int,
            :$query-id, :$final,
        );
    }

    method Str() {
        my $f = self.fraction;
        ($f.defined ?? sprintf('%.1f%% ', $f * 100) !! '')
            ~ "{$!read-rows} rows in {sprintf '%.2fs', self.elapsed}";
    }
}

# --- human-readable formatting ----------------------------------------------

#| 1234567 -> "1.23M". Thresholds match what a reader expects to skim, not SI.
sub fmt-count(Real $n --> Str) is export {
    return $n.Int.Str                    if $n < 1_000;
    return sprintf('%.2fK', $n / 1e3)    if $n < 1_000_000;
    return sprintf('%.2fM', $n / 1e6)    if $n < 1_000_000_000;
    return sprintf('%.2fB', $n / 1e9)    if $n < 1e12;
    sprintf('%.2fT', $n / 1e12);
}

#| Decimal units, matching how ClickHouse itself reports byte counts.
sub fmt-bytes(Real $n --> Str) is export {
    return "{$n.Int} B"                  if $n < 1_000;
    return sprintf('%.2f KB', $n / 1e3)  if $n < 1_000_000;
    return sprintf('%.2f MB', $n / 1e6)  if $n < 1_000_000_000;
    return sprintf('%.2f GB', $n / 1e9)  if $n < 1e12;
    sprintf('%.2f TB', $n / 1e12);
}

#| A terminal progress bar, in the spirit of clickhouse-client's.
#|
#| Pass one straight to query()'s :on-progress — it is callable. It writes to
#| stderr so it never contaminates piped query output, and stays silent when
#| stderr is not a terminal, so cron jobs and test runs are not spammed with
#| escape codes.
class ClickHouse::ProgressBar does Callable {
    has        $.out           = $*ERR;
    has Int    $.width         = 30;
    has Real   $.min-interval  = 0.1;   # seconds between repaints
    has Bool   $.enabled       = $!out.t;
    has Str    $.fill-char     = '━';
    has Str    $.empty-char    = ' ';

    has $!last-paint = 0;
    has Int $!last-width = 0;

    method CALL-ME(ClickHouse::Progress:D $p) { self.update($p) }

    method update(ClickHouse::Progress:D $p --> Nil) {
        return unless $!enabled;
        my $t = now.Real;
        return if !$p.final && $t - $!last-paint < $!min-interval;
        $!last-paint = $t;

        my $frac = $p.fraction;
        my $line = do if $frac.defined {
            my $filled = ($!width * $frac).Int;
            sprintf('  %s%s %5.1f%%  %s rows  %s  %s rows/s',
                $!fill-char x $filled,
                $!empty-char x ($!width - $filled),
                $frac * 100,
                fmt-count($p.read-rows),
                fmt-bytes($p.read-bytes),
                fmt-count($p.rows-per-second));
        } else {
            # No total to divide by — report throughput instead of a fraction.
            sprintf('  %s rows  %s  %s rows/s  %.1fs',
                fmt-count($p.read-rows),
                fmt-bytes($p.read-bytes),
                fmt-count($p.rows-per-second),
                $p.elapsed);
        }
        # Pad over whatever the previous, possibly longer, line left behind.
        my $pad = max(0, $!last-width - $line.chars);
        $!last-width = $line.chars;
        $!out.print("\r" ~ $line ~ (' ' x $pad));
        $!out.flush;
    }

    #| Erase the bar. Call when the query ends, however it ends.
    method clear(--> Nil) {
        return unless $!enabled && $!last-width;
        $!out.print("\r" ~ (' ' x $!last-width) ~ "\r");
        $!out.flush;
        $!last-width = 0;
    }
}
