use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse::Types;

plan 24;

# --- Rat -> decimal string --------------------------------------------------
# Rat.Str truncates at six places, which would silently shave digits off every
# Decimal on the way into the database.
is rational-to-decimal("0.33333333333333333333".FatRat),
   '0.33333333333333333333',                        'terminating decimal is exact';
is rational-to-decimal(123.45),        '123.45',    'simple decimal';
is rational-to-decimal(1/2),           '0.5',       'one half';
is rational-to-decimal(5/1),           '5',         'integral Rat has no point';
is rational-to-decimal(-1/4),          '-0.25',     'negative';
ok rational-to-decimal(1/3).chars > 20,             'repeating fraction is not truncated to 6dp';
isnt (1/3).Str, rational-to-decimal(1/3),           'and differs from Rat.Str';

# --- query parameters -------------------------------------------------------
is encode-param(42),              '42',             'Int param';
is encode-param('plain'),         'plain',          'Str param goes bare';
is encode-param(True),            'true',           'Bool true';
is encode-param(False),           'false',          'Bool false';
is encode-param(Nil),             '\\N',            'undefined is NULL';
is encode-param(Date.new('2026-08-18')), '2026-08-18', 'Date param';
is encode-param(DateTime.new('2026-08-18T14:32:52-04:00')),
   '2026-08-18 18:32:52',                           'DateTime param is UTC, space-separated';
is encode-param(1/3).substr(0, 12), '0.3333333333', 'Rat param keeps digits';
is encode-param([1, 2]),          '[1,2]',          'Array param';
is encode-param(["a'b"]),         q{['a\\'b']},     'Array quotes and escapes elements';

# --- INSERT rows ------------------------------------------------------------
# Same encoder as parameters, on purpose: to-json would emit ISO-8601 datetimes
# that a server running date_time_input_format=basic rejects outright.
is encode-values-row([1, 'a']),       q{(1,'a')},   'simple row';
is encode-values-row([Nil]),          '(NULL)',     'NULL in a row';
is encode-values-row(["o'brien"]),    q{('o\\'brien')}, 'single quote escaped';
is encode-values-row(['back\\slash']), q{('back\\\\slash')}, 'backslash escaped';
is encode-values-row([DateTime.new('2026-08-18T14:32:52-04:00')]),
   q{('2026-08-18 18:32:52')},                      'DateTime in a row';
is encode-values-row([[1,2], ['x']]), q{([1,2],['x'])}, 'arrays in a row';
is encode-values-row([True, False]),  '(true,false)',   'bools in a row';
