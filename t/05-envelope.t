use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse;

plan 8;

# When a query fails after streaming has begun, ClickHouse has already sent
# HTTP 200 and cannot retract it. It appends a tagged envelope to the body
# instead:  __exception__ / <tag> / <message> / <len> <tag> / __exception__
# The tag also appears in X-ClickHouse-Exception-Tag, which is what makes this
# detection exact rather than a guess about content.
my $tag = 'nnuirxstqvpcshcx';
my @trailer = (
    $tag,
    "Code: 395. DB::Exception: boom: while executing 'FUNCTION throwIf(...)'. (FUNCTION_THROW_IF_VALUE_IS_NON_ZERO) (version 26.7.1.1116 (official build))",
    "286 $tag",
    '__exception__',
);

my ($code, $text) = ClickHouse::parse-envelope(@trailer, $tag);
is $code, 395,                                    'exception code is recovered';
ok $text.starts-with('Code: 395. DB::Exception: boom'), 'message is recovered';
nok $text.contains($tag),                         'tag is stripped from the message';
nok $text.contains('__exception__'),              'sentinel is stripped';

# A multi-line message must survive intact.
my @multi = ($tag, 'Code: 241. DB::Exception: Memory limit exceeded',
             'while executing something', "70 $tag", '__exception__');
my ($c2, $t2) = ClickHouse::parse-envelope(@multi, $tag);
is $c2, 241,                                      'multi-line: code';
is $t2.lines.elems, 2,                            'multi-line: both lines kept';

# Without the header tag the parser still has to produce something useful.
my ($c3, $t3) = ClickHouse::parse-envelope(
    ['Code: 60. DB::Exception: Table default.nope does not exist', '55 abcdefghijklmnop', '__exception__'], Str);
is $c3, 60,                                       'no tag available: code still parsed';
ok $t3.contains('does not exist'),                'no tag available: message still parsed';
