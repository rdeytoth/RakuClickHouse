use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse::Types;

plan 27;

# --- integers: arbitrary precision either side of the 64-bit line -----------
is coerce-value(42, 'Int32'),        42,                     'Int32';
is coerce-value(-42, 'Int32'),       -42,                    'negative Int32';
is coerce-value('18446744073709551615', 'UInt64'),
   18446744073709551615,                                     'UInt64 max, quoted';
is coerce-value(18446744073709551615, 'UInt64'),
   18446744073709551615,                                     'UInt64 max, bare';
is coerce-value('-9223372036854775808', 'Int64'),
   -9223372036854775808,                                     'Int64 min';
is coerce-value('170141183460469231731687303715884105727', 'Int128'),
   170141183460469231731687303715884105727,                  'Int128';
isa-ok coerce-value(Nil, 'UInt8'), Int,                      'undefined int is the type object';

# --- decimals: the .Rat trap ------------------------------------------------
# .Rat caps its denominator at 64 bits and goes quietly wrong past ~19
# significant digits; .FatRat does not. The driver asks the server to quote
# decimals so they arrive here as exact strings.
is coerce-value('0.33333333333333333333', 'Decimal(38, 20)').Str,
   '0.33333333333333333333',                                 'Decimal(38,20) exact';
is coerce-value('0.33333333333333333333333333', 'Decimal(38, 26)').Str,
   '0.33333333333333333333333333',                           'Decimal(38,26) exact';
is coerce-value('123.45', 'Decimal(10, 2)').Str, '123.45',   'small decimal';
is coerce-value('-0.5', 'Decimal(10, 2)').Str,   '-0.5',     'negative decimal';
ok coerce-value('0.1', 'Decimal(10,2)') ~~ Rational,         'decimal is Rational';

# --- floats, bools, dates ---------------------------------------------------
ok coerce-value(0.1, 'Float64') ~~ Num,                      'Float64 is Num';
is coerce-value(1, 'Bool'),  True,                           'Bool true';
is coerce-value(0, 'Bool'),  False,                          'Bool false';
is coerce-value('2026-08-18', 'Date'),  Date.new('2026-08-18'), 'Date';
is coerce-value('2026-08-18 18:32:52', 'DateTime'),
   DateTime.new('2026-08-18T18:32:52Z'),                     'DateTime assumed UTC';
is coerce-value('2026-08-18 18:32:52', "DateTime('UTC')"),
   DateTime.new('2026-08-18T18:32:52Z'),                     'DateTime UTC-labelled';
# No zone database in core Raku, so a zoned column is passed through as text
# rather than returned mislabelled as UTC.
is coerce-value('2026-08-18 14:32:52', "DateTime('America/New_York')"),
   '2026-08-18 14:32:52',                                    'zoned DateTime stays a string';

# --- wrappers nest ----------------------------------------------------------
is coerce-value(Nil, 'Nullable(Int32)'),        Nil,         'Nullable NULL';
is coerce-value(7, 'Nullable(Int32)'),          7,           'Nullable set';
is coerce-value('x', 'LowCardinality(String)'), 'x',         'LowCardinality unwraps';
is-deeply coerce-value([1,2,3], 'Array(UInt8)').Array, [1,2,3], 'Array(UInt8)';
is-deeply coerce-value([['1'],['2']], 'Array(Array(UInt64))').Array,
          [[1],[2]],                                         'nested Array';
is-deeply coerce-value([Nil, 3], 'Array(Nullable(Int32))').Array,
          [Nil, 3],                                          'Array of Nullable';

# --- pass-through -----------------------------------------------------------
is coerce-value('abc', 'String'),   'abc',                   'String';
is coerce-value('abc', 'SomeFutureType(9)'), 'abc',          'unknown type passes through';
