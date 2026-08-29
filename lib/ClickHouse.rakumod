use v6.d;
use JSON::Fast;
use ClickHouse::Types;
use ClickHouse::Transport;
use ClickHouse::Progress;

#| Base of the driver's exception hierarchy; thrown as-is when ClickHouse
#| itself rejects a query.
class X::ClickHouse is Exception {
    has $.code;         # ClickHouse exception code
    has $.http-status;  # HTTP status of the failing response, if there was one
    has $.message;      # ClickHouse error text
    method message() { "ClickHouse error {$!code // '?'} (HTTP {$!http-status // '?'}): {$!message}" }
}

#| Transport-level failure: server unreachable, DNS, connection reset, TLS.
#| The query never produced a server verdict — it may not have run at all.
class X::ClickHouse::Connection is X::ClickHouse {
    has $.cause;
    method message() {
        "ClickHouse connection error: {$!cause ~~ Exception ?? $!cause.message !! $!cause}"
    }
}

#| The client-side timeout elapsed. The query may still be running server-side;
#| .query-id says which one, so it can be killed or looked up in query_log.
class X::ClickHouse::Timeout is X::ClickHouse {
    has Real $.seconds;
    has Str  $.query-id;
    method message() {
        "ClickHouse query timed out after {$!seconds}s (query_id {$!query-id // '?'})"
    }
}

#| Raised when an on-progress handler called .cancel. The rows that had already
#| arrived are on .partial — a cancelled scan is still a scan.
class X::ClickHouse::Cancelled is X::ClickHouse {
    has Str $.query-id;
    has     @.partial;
    method message() { "ClickHouse query cancelled (query_id {$!query-id // '?'})" }
}

#| The driver was called wrongly. Nothing was sent to the server.
class X::ClickHouse::Usage is X::ClickHouse {
    has Str $.detail;
    method message() { $!detail }
}

#| A materialised result set from a query().
#| Rows are returned as positional Arrays (column order == .names order).
class ClickHouse::Result {
    has @.names;   # column names, in order
    has @.types;   # raw ClickHouse type strings, in order
    has @.rows;    # list of Arrays; each value already coerced to a Raku type
    has Str $.query-id;
    #| Final server counters (rows read, bytes read, elapsed). Undefined if the
    #| server sent no summary.
    has ClickHouse::Progress $.summary;

    #| Convenience: rows as a List of Hashes keyed by column name.
    method hashes(--> List) {
        @!rows.map(-> @r { %(@!names Z=> @r) }).List;
    }
    method elems(--> Int) { @!rows.elems }
}

my sub new-query-id(--> Str) {
    'raku-' ~ (^32).map({ '0123456789abcdef'.substr((^16).pick, 1) }).join;
}

#| Type-aware ClickHouse driver for Raku, speaking the HTTP interface.
#|
#| Depends only on JSON::Fast: the HTTP transport is part of the distribution
#| because the driver needs the response body delivered while the query is
#| still running, so live progress can be reported.
class ClickHouse {
    has Str  $.host      = 'localhost';
    has Int  $.port      = 8123;
    has Str  $.user      = 'default';
    has Str  $.password  = '';
    has Str  $.database  = 'default';
    has Str  $.scheme    = 'http';
    has Str  $.timezone  = 'UTC';   # sent as session_timezone so DateTime values
                                    # are rendered in a known zone; '' disables
                                    # (needs ClickHouse >= 23.6)
    has Bool $.readonly  = False;   # True sends readonly=2 with every request:
                                    # a read-only handle that can never mutate data
    has Real $.timeout;             # total per-request timeout in seconds
                                    # (undefined = no client-side bound)
    has %.settings;                 # default per-request ClickHouse settings
    has %.tls-config;               # passed to IO::Socket::Async::SSL for https
    #| Progress handler used by every call that does not name its own.
    has &.on-progress;

    has ClickHouse::Transport::Connection $!conn;

    submethod TWEAK {
        $!conn = ClickHouse::Transport::Connection.new(
            host => $!host, port => $!port,
            tls  => $!scheme.lc eq 'https',
            tls-config => %!tls-config,
        );
    }

    method !auth-headers() {
        (
            'X-ClickHouse-User' => $!user,
            'X-ClickHouse-Key'  => $!password,
            'Content-Type'      => 'text/plain; charset=utf-8',
        ).Hash;
    }

    #| Settings the driver always sends. Both make the JSON wire form lossless:
    #| unquoted, they are parsed as floats and Decimal128/256 arrive already
    #| mangled, before any Raku code can intervene.
    method !wire-settings() {
        (
            output_format_json_quote_decimals       => 1,
            output_format_json_quote_64bit_integers => 1,
        ).Hash;
    }

    # --- the single HTTP seam ------------------------------------------------
    method !post(Str:D $body, :%settings, :%params, :&on-line!, :&on-header,
                 Str :$query-id, Str :$path = '/', Str :$method = 'POST',
                 Bool :$wire = False, Bool :$bare = False) {
        # /ping answers 404 to any request carrying a query string, so the
        # liveness check has to go out naked.
        my %query = $bare ?? {} !! build-query-params(
            database         => $!database,
            timezone         => $!timezone,
            readonly         => $!readonly,
            default-settings => %(|($wire ?? self!wire-settings !! {}), |%!settings),
            settings         => %settings,
            params           => %params,
        );
        %query<query_id> = $query-id if $query-id && !$bare;

        my $resp;
        {
            CATCH {
                when X::ClickHouse         { .rethrow }
                when X::Transport::Timeout {
                    die X::ClickHouse::Timeout.new(seconds => .seconds, :$query-id);
                }
                default {
                    die X::ClickHouse::Connection.new(cause => $_);
                }
            }
            $resp = with-timeout($!timeout, $!conn, {
                $!conn.request(
                    :%query, :$path, :$method,
                    body    => $body.encode('utf-8'),
                    headers => self!auth-headers,
                    :&on-line, :&on-header,
                );
            });
        }
        $resp;
    }

    # --- statement preparation ----------------------------------------------
    # Words that can legitimately end a statement and would otherwise look like
    # "FORMAT <name>" to a naive check, e.g. ORDER BY format DESC.
    my $NOT-A-FORMAT = /^ :i [ desc | asc | first | last | nulls | using ] $/;

    my sub user-format(Str:D $sql) {
        return Nil unless $sql ~~ / :i \s 'format' \s+ (\w+) \s* $/;
        my $name = ~$0;
        $name ~~ $NOT-A-FORMAT ?? Nil !! $name;
    }

    my sub strip-semicolon(Str:D $sql --> Str) {
        $sql.trim.subst(/ ';' \s* $/, '');
    }

    # --- result parsing ------------------------------------------------------
    #| Consume one line of a *WithProgress stream. Returns the state needed to
    #| tell rows, metadata, progress and the exception envelope apart.
    method !make-line-handler(
        @names, @types, @rows, @trailer, @other, $state,
        :&on-progress, :$query-id, :$collect = True, :&on-row,
    ) {
        -> $line {
            if $state<trailer> {
                @trailer.push: $line;
            }
            elsif $line eq '__exception__' {
                # ClickHouse cannot retract an HTTP 200 it has already sent, so
                # a query that fails mid-stream reports it here instead.
                $state<trailer> = True;
            }
            elsif $line.starts-with('{') {
                my %o := from-json($line);
                with %o<row> {
                    my @raw := $_.list;
                    my @row = (^@raw).map({ coerce-value(@raw[$_], @types[$_]) });
                    $collect ?? @rows.push(@row) !! on-row(@row);
                }
                orwith %o<meta> {
                    @names = $_.map(*.<name>);
                    @types = $_.map(*.<type>);
                }
                orwith %o<progress> {
                    my $p = ClickHouse::Progress.from-json($_, :$query-id);
                    $state<progress> = $p;
                    on-progress($p) if &on-progress;
                    if $p.cancel-requested {
                        $state<cancelled> = True;
                        die X::ClickHouse::Cancelled.new(:$query-id, partial => @rows);
                    }
                }
                orwith %o<exception> {
                    $state<trailer> = True;
                    @trailer.push: $_.Str;
                }
                orwith %o<totals> { }
            }
            elsif $line.trim {
                # Not our format at all: an error body from a non-2xx response.
                # Keep a bounded head of it so the exception can quote it.
                @other.push: $line if @other < 40;
            }
        }
    }

    #| Turn the exception envelope ClickHouse appends to a partially-streamed
    #| response into a real error. The envelope is
    #|   __exception__ / <tag> / <message...> / <len> <tag> / __exception__
    #| where <tag> also appears in the X-ClickHouse-Exception-Tag header, which
    #| is what makes detection unambiguous rather than a guess about content.
    our sub parse-envelope(@trailer, $tag) is export(:testing) {
        my @lines = @trailer.grep({ $_ ne '__exception__' });
        @lines.shift if @lines && $tag.defined && @lines[0] eq $tag;
        @lines.pop   if @lines && $tag.defined && @lines[*-1] ~~ / ^ \d+ ' ' $tag $/;
        @lines.pop   if @lines && @lines[*-1] ~~ / ^ \d+ ' ' \w+ $/;
        my $text = @lines.join("\n").trim;
        my $code = $text ~~ / ^ 'Code: ' (\d+) / ?? +$0 !! Nil;
        ($code, $text);
    }

    #| Raise whatever this response actually represents, or return quietly.
    method !check(ClickHouse::Transport::Response:D $resp, @trailer, $body-head) {
        if @trailer {
            my ($code, $text) = parse-envelope(@trailer, $resp.header('x-clickhouse-exception-tag'));
            die X::ClickHouse.new(:$code, http-status => $resp.status, message => $text);
        }
        unless $resp.ok {
            die X::ClickHouse.new(
                code        => $resp.header('x-clickhouse-exception-code'),
                http-status => $resp.status,
                message     => ($body-head // '').trim,
            );
        }
        if $resp.truncated {
            die X::ClickHouse::Connection.new(
                cause => 'server closed the connection before the response was complete');
        }
    }

    #| Final counters for a finished query.
    #|
    #| X-ClickHouse-Summary is not reliable on its own: for a streaming
    #| response the header block is flushed early, so the summary it carries
    #| describes the query's first few hundred milliseconds rather than its
    #| end. The last in-body {"progress":...} record is the one that reports
    #| the whole scan. Take whichever actually saw more rows.
    my sub summary-of(ClickHouse::Transport::Response:D $resp, Str $query-id, $last-progress) {
        my $header = do with $resp.header('x-clickhouse-summary') {
            ClickHouse::Progress.from-json(from-json($_.List[*-1].Str), :$query-id, :final);
        } else {
            ClickHouse::Progress;
        }
        return $header unless $last-progress.defined;
        return $last-progress.clone(:final) unless $header.defined;
        $header.read-rows >= $last-progress.read-rows ?? $header !! $last-progress.clone(:final);
    }

    #| Run a statement that returns a result set (typically SELECT / SHOW).
    #| The response format is managed for you; do not add your own FORMAT.
    #|
    #| :%params fills {name:Type} placeholders server-side — no string
    #| interpolation, no SQL injection:
    #|   $ch.query('SELECT * FROM t WHERE id = {id:UInt64}', params => { id => 42 })
    #|
    #| :&on-progress is called with a ClickHouse::Progress roughly every 100ms
    #| while the query runs. Pass a ClickHouse::ProgressBar for a terminal bar,
    #| or call .cancel on the snapshot to stop the query.
    method query(Str:D $sql, :%params, :%settings, :&on-progress,
                 Str :$query-id is copy --> ClickHouse::Result) {
        my $stmt = strip-semicolon($sql);
        with user-format($stmt) {
            die X::ClickHouse::Usage.new(detail =>
                "query() manages the response FORMAT itself (found 'FORMAT $_'). "
              ~ "Use execute() for statements whose output you format yourself.");
        }
        $stmt ~= "\nFORMAT JSONCompactEachRowWithProgress";
        $query-id //= new-query-id();
        my $handler = &on-progress // &!on-progress;

        my (@names, @types, @rows, @trailer, @other);
        my %state;

        my $resp = self!post($stmt, :%settings, :%params, :$query-id, :wire,
            on-line => self!make-line-handler(@names, @types, @rows, @trailer, @other, %state,
                                              on-progress => $handler, :$query-id));

        CATCH {
            when X::ClickHouse::Cancelled {
                self!kill-query($query-id);
                .rethrow;
            }
        }

        self!check($resp, @trailer, @other.join("\n"));
        ClickHouse::Result.new(:@names, :@types, :@rows, :$query-id,
                               summary => summary-of($resp, $query-id, %state<progress>));
    }

    #| Stream rows to a callback instead of materialising them. Memory stays
    #| flat regardless of result size, which is the difference between scanning
    #| a billion rows and running out of RAM.
    #| Returns the ClickHouse::Result with .rows empty but .summary populated.
    method each(Str:D $sql, &on-row, :%params, :%settings, :&on-progress,
                Str :$query-id is copy --> ClickHouse::Result) {
        my $stmt = strip-semicolon($sql);
        with user-format($stmt) {
            die X::ClickHouse::Usage.new(detail =>
                "each() manages the response FORMAT itself (found 'FORMAT $_').");
        }
        $stmt ~= "\nFORMAT JSONCompactEachRowWithProgress";
        $query-id //= new-query-id();
        my $handler = &on-progress // &!on-progress;

        my (@names, @types, @rows, @trailer, @other);
        my %state;

        my $resp = self!post($stmt, :%settings, :%params, :$query-id, :wire,
            on-line => self!make-line-handler(@names, @types, @rows, @trailer, @other, %state,
                                              on-progress => $handler, :$query-id,
                                              :!collect, :&on-row));
        CATCH {
            when X::ClickHouse::Cancelled { self!kill-query($query-id); .rethrow }
        }
        self!check($resp, @trailer, @other.join("\n"));
        ClickHouse::Result.new(:@names, :@types, :$query-id,
                               summary => summary-of($resp, $query-id, %state<progress>));
    }

    #| Run a statement with no result set (DDL, INSERT ... VALUES, etc).
    #| Use query() if you need rows back. Throws X::ClickHouse on failure.
    #|
    #| Progress for these comes from repeated X-ClickHouse-Progress headers
    #| rather than the response body, since there is no body to interleave it
    #| with; :&on-progress works the same way from the caller's side.
    method execute(Str:D $sql, :%params, :%settings, :&on-progress,
                   Str :$query-id is copy --> Bool) {
        $query-id //= new-query-id();
        my $handler = &on-progress // &!on-progress;
        my @body;
        my %opts = $handler ?? (settings => %(|%settings, send_progress_in_http_headers => 1)) !! (settings => %settings);

        my $resp = self!post(strip-semicolon($sql), |%opts, :%params, :$query-id,
            on-line   => -> $l { @body.push: $l if @body < 40 },
            on-header => $handler
                ?? -> $k, $v {
                       if $k.lc eq 'x-clickhouse-progress' {
                           $handler(ClickHouse::Progress.from-json(from-json($v), :$query-id));
                       }
                   }
                !! Callable,
        );
        my @trailer = @body.grep({ $_ eq '__exception__' }) ?? @body !! ();
        self!check($resp, @trailer, @body.join("\n"));
        True;
    }

    #| For backward compatibility with the Perl5 ClickHouse module
    #| formerly used via Inline::Perl5
    method select(Str:D $sql, :%params, :%settings) {
        return self.query($sql, :%params, :%settings).rows;
    }
    method do(Str:D $sql, :%params, :%settings --> Bool) {
        return self.execute($sql, :%params, :%settings);
    }

    #| Bulk INSERT. @rows is a list of positional Arrays whose order matches
    #| @columns (or the table's column order if @columns is omitted).
    #|
    #| Values go through the same encoder as query parameters, so a DateTime
    #| lands as the unambiguous 'YYYY-MM-DD hh:mm:ss' UTC form and a Rat keeps
    #| its digits. Rows are sent in batches so a large load does not first have
    #| to fit in memory as one string.
    method insert(Str:D $table, @rows, :@columns, :%settings, :&on-progress,
                  Int :$batch-size = 10_000 --> Bool) {
        return True unless @rows;
        my $cols = @columns ?? '(' ~ @columns.join(', ') ~ ')' !! '';
        my $head = "INSERT INTO $table$cols VALUES ";
        for @rows.batch($batch-size) -> @batch {
            self.execute($head ~ @batch.map({ encode-values-row($_.list) }).join(','),
                         :%settings, :&on-progress);
        }
        True;
    }

    #| Liveness check. Returns True if the server answers /ping with "Ok.".
    method ping(--> Bool) {
        my @lines;
        my $resp = try self!post('', path => '/ping', method => 'GET', :bare,
                                 on-line => -> $l { @lines.push: $l });
        return False unless $resp.defined && $resp !~~ Failure && $resp.ok;
        @lines.join.trim eq 'Ok.';
    }

    #| Stop a running query. Uses its own connection, because the one running
    #| the query is busy streaming it.
    method !kill-query(Str:D $query-id) {
        my $side = ClickHouse::Transport::Connection.new(
            host => $!host, port => $!port,
            tls  => $!scheme.lc eq 'https', tls-config => %!tls-config,
        );
        try {
            $side.request(
                query   => { database => $!database },
                body    => "KILL QUERY WHERE query_id = '$query-id' ASYNC".encode('utf-8'),
                headers => self!auth-headers,
                on-line => -> $l { },
            );
        }
        try $side.close;
    }

    #| Close the underlying connection. The object stays usable; the next call
    #| reconnects.
    method close(--> Nil) { .close with $!conn; }
}
