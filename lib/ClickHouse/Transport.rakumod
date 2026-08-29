use v6.d;

#| Minimal HTTP/1.1 client specialised for ClickHouse.
#|
#| Why not a general HTTP library: the driver needs the response body delivered
#| *line by line while the query is still running*, so that {"progress":...}
#| records can drive a progress bar. That rules out any client whose only
#| interface is "await the whole body", and Cro::HTTP additionally drags in a
#| dependency chain that fails to build on older Rakudo. What ClickHouse
#| actually needs from HTTP is one POST with a query string, so it is cheaper
#| to speak it directly than to depend on a stack that speaks all of it.
unit module ClickHouse::Transport;

#| Anything that fails below the ClickHouse protocol itself: DNS, connect,
#| reset, TLS handshake, truncated response, client-side timeout.
class X::Transport is Exception is export {
    has $.cause;
    has Str $.detail;
    method message() {
        my $why = $!cause ~~ Exception ?? $!cause.message
               !! $!cause.defined      ?? ~$!cause
               !!                         'connection closed';
        $!detail ?? "$!detail: $why" !! $why;
    }
}

class X::Transport::Timeout is X::Transport is export {
    has Real $.seconds;
    method message() { "timed out after {$!seconds}s" }
}

#| Status line + headers of one response. The body never lands here; it is
#| streamed to the caller's line callback as it arrives.
class Response is export {
    has Int  $.status;
    has      %.headers;
    #| True when the connection ended before the body was properly framed.
    #| ClickHouse does this deliberately when a query fails after streaming has
    #| begun: it writes the exception envelope, then drops the socket. The body
    #| collected so far is still meaningful and carries the error.
    has Bool $.truncated is rw = False;
    method header(Str:D $name) { %!headers{$name.lc} }
    method ok(--> Bool)        { 200 <= $!status < 300 }
}

# --- byte helpers -----------------------------------------------------------
# Buf index scans, written with native ints; these run per response chunk.

my sub find-byte(Buf:D $b, int $from, int $needle --> int) {
    my int $n = $b.elems;
    loop (my int $i = $from; $i < $n; $i++) {
        return $i if $b.AT-POS($i) == $needle;
    }
    -1;
}

my sub find-crlf(Buf:D $b, int $from --> int) {
    my int $n = $b.elems - 1;
    loop (my int $i = $from; $i < $n; $i++) {
        return $i if $b.AT-POS($i) == 13 && $b.AT-POS($i + 1) == 10;
    }
    -1;
}

#| Percent-encode one query-string component.
sub uri-escape(Str() $s --> Str) is export {
    $s.encode('utf-8').list.map(-> $o {
        (48 <= $o <= 57) || (65 <= $o <= 90) || (97 <= $o <= 122)
            || $o == 45 || $o == 46 || $o == 95 || $o == 126
            ?? $o.chr !! sprintf('%%%02X', $o)
    }).join;
}

#| Splits a byte stream into text lines, emitting each complete line to a
#| callback the moment its newline arrives. A trailing \r is stripped, so
#| both the \n-terminated data lines and the \r\n-terminated exception
#| envelope come out clean.
my class LineSplitter {
    has Buf  $!acc = Buf.new;
    has      &.on-line is required;

    method feed(Blob:D $bytes) {
        $!acc.append($bytes);
        my int $start = 0;
        loop {
            my int $nl = find-byte($!acc, $start, 10);
            last if $nl < 0;
            my int $end = ($nl > $start && $!acc.AT-POS($nl - 1) == 13) ?? $nl - 1 !! $nl;
            &!on-line($!acc.subbuf($start, $end - $start).decode('utf-8'));
            $start = $nl + 1;
        }
        $!acc = $start > 0 ?? $!acc.subbuf($start) !! $!acc;
    }

    #| Flush a final line that arrived without a trailing newline.
    method finish() {
        if $!acc.elems {
            my int $end = $!acc.elems;
            $end-- if $!acc.AT-POS($end - 1) == 13;
            &!on-line($!acc.subbuf(0, $end).decode('utf-8')) if $end;
            $!acc = Buf.new;
        }
    }
}

# --- TLS is a soft dependency ------------------------------------------------
# Plain http:// works with core Raku alone; https:// pulls this in on first use.
my $SSL-CLASS;
my $SSL-TRIED = False;
my sub ssl-class() {
    unless $SSL-TRIED {
        $SSL-TRIED = True;
        $SSL-CLASS = try {
            require ::('IO::Socket::Async::SSL');
            ::('IO::Socket::Async::SSL');
        };
    }
    # A class is a type object, so .defined is always False here — ask whether
    # it can actually do the job instead.
    unless so (try $SSL-CLASS.^can('connect')) {
        die X::Transport.new(detail => 'https requested',
            cause => "IO::Socket::Async::SSL is not installed (zef install IO::Socket::Async::SSL)");
    }
    $SSL-CLASS;
}

#| One keep-alive connection to a ClickHouse HTTP endpoint. Not thread-safe:
#| one Connection serves one request at a time, which is what a pool is for.
class Connection is export {
    has Str  $.host is required;
    has Int  $.port is required;
    has Bool $.tls  = False;
    has      %.tls-config;

    has       $!sock;
    has Channel $!chan;
    has Buf   $!buf = Buf.new;
    has int   $!pos = 0;
    has Bool  $!eof = False;
    has Bool  $!open = False;
    has Bool  $!used = False;    # has this connection already served a request?
    has       $!quit-cause;

    method open(--> Bool) { $!open }

    method close() {
        if $!sock {
            try $!sock.close;
        }
        $!sock = Nil; $!chan = Nil; $!open = False; $!used = False;
        $!buf = Buf.new; $!pos = 0; $!eof = False; $!quit-cause = Nil;
    }

    method !connect() {
        my $chan = Channel.new;
        my $sock = do {
            CATCH {
                default {
                    die X::Transport.new(cause => $_,
                        detail => "connect to {$!host}:{$!port}");
                }
            }
            $!tls
                ?? await ssl-class().connect($!host, $!port, |%!tls-config)
                !! await IO::Socket::Async.connect($!host, $!port);
        }
        $sock.Supply(:bin).tap(
            -> $bytes { $chan.send($bytes) },
            done      => { $chan.close },
            quit      => -> $err { $!quit-cause = $err; $chan.close },
        );
        $!sock = $sock; $!chan = $chan;
        $!buf = Buf.new; $!pos = 0; $!eof = False; $!open = True; $!used = False;
    }

    # Pull one more chunk from the socket. False means end of stream.
    method !fill(--> Bool) {
        return False if $!eof;
        my $chunk = try $!chan.receive;
        without $chunk { $!eof = True; return False }
        # Drop the consumed prefix so a long response does not grow without bound.
        if $!pos > 65536 {
            $!buf = $!buf.subbuf($!pos);
            $!pos = 0;
        }
        $!buf.append($chunk);
        True;
    }

    method !avail(--> int) { $!buf.elems - $!pos }

    method !ensure(int $n --> Bool) {
        while self!avail < $n {
            return False unless self!fill;
        }
        True;
    }

    # Index of the next CRLF at or after $!pos, filling as needed; -1 at EOF.
    method !ensure-crlf(--> int) {
        loop {
            my int $i = find-crlf($!buf, $!pos);
            return $i if $i >= 0;
            return -1 unless self!fill;
        }
    }

    method !truncated() {
        die X::Transport.new(cause => $!quit-cause, detail => 'response truncated');
    }

    method !read-headers(:&on-header --> Response) {
        my int $i = self!ensure-crlf;
        self!truncated if $i < 0;
        my $status-line = $!buf.subbuf($!pos, $i - $!pos).decode('latin-1');
        $!pos = $i + 2;
        my $status = +($status-line.words[1] // 0);

        my %headers;
        loop {
            my int $j = self!ensure-crlf;
            self!truncated if $j < 0;
            my int $len = $j - $!pos;
            my $line = $!buf.subbuf($!pos, $len).decode('latin-1');
            $!pos = $j + 2;
            last if $len == 0;
            my ($k, $v) = $line.split(': ', 2);
            # Fire as parsed, not after: ClickHouse streams repeated
            # X-ClickHouse-Progress headers while the statement is still
            # running, which is the only progress signal an INSERT or a DDL
            # statement has to offer.
            &on-header($k, $v // '') if &on-header;
            # ClickHouse repeats X-ClickHouse-Progress; keep every value.
            my $key = $k.lc;
            if %headers{$key}:exists {
                %headers{$key} = [|%headers{$key}.List, $v // ''];
            } else {
                %headers{$key} = $v // '';
            }
        }
        Response.new(:$status, :%headers);
    }

    method !read-body(Response:D $resp, LineSplitter:D $split) {
        my $te = ($resp.header('transfer-encoding') // '').Str.lc;
        my $cl = $resp.header('content-length');

        if $te.contains('chunked') {
            CHUNKS: loop {
                my int $i = self!ensure-crlf;
                if $i < 0 { $resp.truncated = True; last CHUNKS }
                my $size-line = $!buf.subbuf($!pos, $i - $!pos).decode('latin-1');
                $!pos = $i + 2;
                my $hex = $size-line.split(';')[0].trim;
                my int $size = $hex ?? :16($hex) !! 0;
                if $size == 0 {
                    # Consume any trailers, then the terminating blank line.
                    loop {
                        my int $j = self!ensure-crlf;
                        last if $j < 0;
                        my int $len = $j - $!pos;
                        $!pos = $j + 2;
                        last if $len == 0;
                    }
                    last CHUNKS;
                }
                # Feed the chunk out in whatever slices actually arrive, rather
                # than waiting for the whole chunk: that is what keeps progress
                # lines timely.
                my int $left = $size;
                while $left > 0 {
                    if self!avail == 0 && !self!fill {
                        $resp.truncated = True;
                        last CHUNKS;
                    }
                    my int $take = min($left, self!avail);
                    $split.feed($!buf.subbuf($!pos, $take));
                    $!pos += $take;
                    $left -= $take;
                }
                unless self!ensure(2) { $resp.truncated = True; last CHUNKS }
                $!pos += 2;
            }
        }
        elsif $cl.defined {
            my int $left = +$cl.Str;
            while $left > 0 {
                if self!avail == 0 && !self!fill {
                    $resp.truncated = True;
                    last;
                }
                my int $take = min($left, self!avail);
                $split.feed($!buf.subbuf($!pos, $take));
                $!pos += $take;
                $left -= $take;
            }
        }
        else {
            # No framing: body runs to end of connection.
            loop {
                if self!avail > 0 {
                    $split.feed($!buf.subbuf($!pos, self!avail));
                    $!pos = $!buf.elems;
                }
                last unless self!fill;
            }
        }
        $split.finish;
    }

    #| Send one POST and stream the response body to &on-line.
    #| Retries once, transparently, if a reused keep-alive connection turns
    #| out to have been closed by the server before we wrote to it.
    method request(:%query!, Blob:D :$body!, :%headers, :&on-line!, :&on-header,
                   Str :$path = '/', Str :$method = 'POST' --> Response) {
        my $attempt = 0;
        loop {
            $attempt++;
            self!connect unless $!open;
            my $was-used = $!used;
            my $emitted  = 0;
            my $callback-threw = False;

            my $result = try {
                my $qs = %query.sort(*.key)
                    .map({ uri-escape(.key) ~ '=' ~ uri-escape(.value.Str) }).join('&');
                my $target = $qs ?? "$path?$qs" !! $path;

                my $head = "$method $target HTTP/1.1\r\n"
                         ~ "Host: {$!host}:{$!port}\r\n"
                         ~ "Connection: keep-alive\r\n"
                         ~ "Content-Length: {$body.bytes}\r\n"
                         ~ %headers.sort(*.key).map({ "{.key}: {.value}\r\n" }).join
                         ~ "\r\n";

                await $!sock.write($head.encode('latin-1'));
                await $!sock.write($body) if $body.bytes;
                $!used = True;

                my $resp = self!read-headers(:&on-header);
                my $split = LineSplitter.new(on-line => -> $line {
                    $emitted++;
                    &on-line($line);
                    # Distinguish "the caller's handler aborted" from "the
                    # network failed"; only the latter may be retried.
                    CATCH { default { $callback-threw = True; .rethrow } }
                });
                self!read-body($resp, $split);

                # Honour the server's wish to close, and never reuse a
                # connection whose framing we are unsure of.
                self.close if $resp.truncated
                    || ($resp.header('connection') // '').Str.lc.contains('close');
                $resp;
            };

            return $result if $result.defined && $result !~~ Failure;

            my $err = $!;
            self.close;
            # An abort raised by the caller's own handler is theirs to see,
            # unwrapped and unretried.
            $err.rethrow if $callback-threw;
            # A reused connection that died before producing anything is the
            # classic keep-alive race: the server timed the socket out while it
            # sat idle. One clean retry, and only then.
            next if $attempt == 1 && $was-used && $emitted == 0;
            $err ~~ X::Transport ?? $err.rethrow !! die X::Transport.new(cause => $err);
        }
    }
}

#| Run $body, aborting it if it outlives $seconds. The socket is closed from
#| the outside, which is what unblocks a read parked in the middle of a query.
sub with-timeout(Real $seconds, Connection:D $conn, &body) is export {
    return body() unless $seconds.defined && $seconds > 0;
    my $work = start { body() };
    await Promise.anyof($work, Promise.in($seconds));
    unless $work.status ~~ Kept | Broken {
        $conn.close;                     # unblock the reader
        try await $work;                 # let it unwind
        die X::Transport::Timeout.new(seconds => $seconds);
    }
    await $work;
}
