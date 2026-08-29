use v6.d;

# Dependency-free type layer for the ClickHouse driver.
#  - coerce-value: JSON-decoded value + ClickHouse type string -> native Raku value.
#    Driven entirely by the type strings the server sends alongside the data,
#    so 64-bit ints and decimals stay lossless instead of collapsing into floats.
#  - encode-param: Raku value -> the string form ClickHouse expects for a
#    server-side query parameter (param_<name>=<value> over HTTP).
#  - encode-values-row: Raku values -> one VALUES tuple for INSERT.
#
# Reads and writes share one encoder on purpose: an asymmetry between them is
# how a driver ends up storing something it cannot read back.

#| Render a Rational as a decimal string without losing digits.
#|
#| Rat.Str truncates — (1/3).Str is "0.333333" — which silently destroys
#| precision on the way to a Decimal column. A denominator built only from 2s
#| and 5s terminates in base 10 and is emitted exactly; anything else (a true
#| repeating fraction) is capped, since it has no finite decimal form anyway.
sub rational-to-decimal(Rational:D $r --> Str) is export {
    my ($n, $d) = $r.nude;
    return $n.Str if $d == 1;
    my $t = $d;
    my $twos = 0;
    my $fives = 0;
    while $t %% 2 { $t = $t div 2; $twos++ }
    while $t %% 5 { $t = $t div 5; $fives++ }
    my $digits = $t == 1 ?? max($twos, $fives, 1) !! 30;
    my $s = $r.base(10, $digits);
    $s.contains('.') ?? $s.subst(/ '0'+ $ /, '').subst(/ '.' $ /, '') !! $s;
}

#| Coerce one JSON-decoded value according to its ClickHouse type string.
sub coerce-value($val, $type is copy) is export {
    return $val without $type;
    $type .= trim;

    # Wrappers first (they nest arbitrarily).
    if $type ~~ /^ 'LowCardinality(' (.+) ')' $/ {
        return coerce-value($val, ~$0);
    }
    if $type ~~ /^ 'Nullable(' (.+) ')' $/ {
        return $val.defined ?? coerce-value($val, ~$0) !! Nil;
    }
    if $type ~~ /^ 'Array(' (.+) ')' $/ {
        my $inner = ~$0;
        return ($val // []).map({ coerce-value($_, $inner) }).Array;
    }

    given $type {
        when /^ 'U'? 'Int' [8 | 16 | 32 | 64 | 128 | 256] $/ {
            # Arrives quoted or bare depending on the server's
            # output_format_json_quote_64bit_integers; .Int handles both, and
            # Raku's Int is arbitrary precision either way.
            return $val.defined ?? $val.Int !! Int;
        }
        when /^ 'Float' [32 | 64] $/ {
            return $val.defined ?? $val.Num !! Num;
        }
        when /^ 'Decimal' / {
            return FatRat unless $val.defined;
            # The driver sets output_format_json_quote_decimals=1 so these
            # arrive as exact strings. FatRat parses them without the 64-bit
            # denominator ceiling that makes .Rat silently wrong past ~19
            # significant digits.
            my $s = $val ~~ Str ?? $val !! $val.Str;
            return (try $s.FatRat) // (try $s.Rat) // $val;
        }
        when 'Bool' | 'Boolean' {
            return $val.defined ?? $val.so !! Bool;
        }
        when /^ 'Date' '32'? $/ {
            return $val.defined ?? Date.new($val) !! Date;
        }
        when /^ 'DateTime' / {
            return DateTime unless $val.defined;
            # A column-level timezone, e.g. DateTime('Europe/London') or
            # DateTime64(3, 'Asia/Tokyo'): the server renders values in THAT
            # zone regardless of session_timezone. Core Raku has no zone
            # database to map the name to an offset, so rather than return a
            # DateTime mislabelled as UTC, pass the raw string through.
            # (UTC-labelled columns are safe to parse.)
            if $type ~~ / "'" (<-[']>+) "'" / {
                return ~$0 eq 'UTC' ?? (try DateTime.new($val.subst(' ', 'T') ~ 'Z')) // $val
                                    !! $val;
            }
            my $iso = $val.subst(' ', 'T');
            # add a zone only if the value carries no explicit offset/Z;
            # correct as long as the connection pins session_timezone=UTC
            # (the driver's default).
            $iso ~= 'Z' unless $iso ~~ / <[Z]> $ / || $iso ~~ / <[+\-]> \d\d ':'? \d\d $ /;
            return (try DateTime.new($iso)) // $val;   # fall back to raw string
        }
        # String, FixedString, UUID, Enum*, IPv4/6, JSON, Tuple, Map, and any
        # unknown type pass through as-is (already Str/structure from JSON).
        default { return $val; }
    }
}

# --- shared value encoding ---------------------------------------------------

my sub format-datetime(DateTime $dt --> Str) {
    my $u    = $dt.utc;
    my $base = sprintf '%04d-%02d-%02d %02d:%02d:%02d',
        $u.year, $u.month, $u.day, $u.hour, $u.minute, $u.whole-second;
    my $frac = $u.second - $u.whole-second;
    if $frac > 0 {
        $base ~= sprintf('%.6f', $frac).substr(1).subst(/ '0'+ $ /, '').subst(/ '.' $ /, '');
    }
    $base;
}

my sub quoted(Str() $s --> Str) {
    "'" ~ $s.trans([ '\\', "'" ] => [ '\\\\', "\\'" ]) ~ "'"
}

# Element form: how a value appears INSIDE an Array/Map literal or a VALUES
# tuple, where strings and dates must be single-quoted and escaped, but
# numbers stay bare.
my sub encode-element($val --> Str) {
    return 'NULL' without $val;
    given $val {
        when Bool        { $val ?? 'true' !! 'false' }   # before Numeric: Bool is an Int
        when Int         { $val.Str }
        when Rational    { rational-to-decimal($val) }
        when Numeric     { $val.Str }
        when DateTime    { quoted(format-datetime($val)) }
        when Dateish     { quoted($val.Str) }
        when Positional  { '[' ~ $val.map(&encode-element).join(',') ~ ']' }
        when Associative { '{' ~ $val.sort(*.key).map({ encode-element(.key) ~ ':' ~ encode-element(.value) }).join(',') ~ '}' }
        default          { quoted($val.Str) }
    }
}

#| One row rendered as a VALUES tuple: (1,'a','2026-01-01 00:00:00',NULL).
#|
#| INSERT goes through the same encoder as query parameters rather than
#| through to-json, which would emit ISO-8601 datetimes that a server running
#| date_time_input_format=basic rejects outright, and would truncate Rats to
#| six decimal places on the way past.
sub encode-values-row(@row --> Str) is export {
    '(' ~ @row.map(&encode-element).join(',') ~ ')';
}

#| Assemble the URL query parameters for one request: connection identity,
#| timezone/readonly flags, per-connection then per-call settings (later
#| entries win on collision), then param_* values for {name:Type} placeholders.
sub build-query-params(Str:D :$database!, Str :$timezone, Bool :$readonly,
                       :%default-settings, :%settings, :%params --> Hash) is export {
    my %q = :$database;
    %q<session_timezone> = $timezone if $timezone;
    %q<readonly>         = 2         if $readonly;
    %q{.key} = .value for flat %default-settings.pairs, %settings.pairs;
    %q{'param_' ~ .key} = encode-param(.value) for %params.pairs;
    %q
}

#| Encode one Raku value as the value of a param_<name> HTTP query parameter,
#| matching a {name:Type} placeholder server-side. Top-level scalars go bare
#| (the server parses them according to the declared type); values nested in
#| Array/Map literals are quoted and escaped. DateTime is sent in UTC, which
#| matches the driver's session_timezone=UTC default. Undefined -> NULL (\N).
sub encode-param($val --> Str) is export {
    return '\N' without $val;
    given $val {
        when Bool        { $val ?? 'true' !! 'false' }
        when Rational    { rational-to-decimal($val) }
        when DateTime    { format-datetime($val) }
        when Dateish     { $val.Str }
        when Positional  { '[' ~ $val.map(&encode-element).join(',') ~ ']' }
        when Associative { '{' ~ $val.sort(*.key).map({ encode-element(.key) ~ ':' ~ encode-element(.value) }).join(',') ~ '}' }
        default          { $val.Str }
    }
}
