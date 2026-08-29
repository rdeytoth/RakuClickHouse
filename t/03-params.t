use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');
use ClickHouse::Types;
use ClickHouse::Transport;

plan 11;

my %q = build-query-params(database => 'db', timezone => 'UTC', readonly => False);
is %q<database>, 'db',                            'database is sent';
is %q<session_timezone>, 'UTC',                   'timezone is sent';
nok %q<readonly>:exists,                          'readonly absent when False';

my %r = build-query-params(database => 'db', readonly => True);
is %r<readonly>, 2,                               'readonly=2 for a read-only handle';

my %s = build-query-params(
    database => 'db',
    default-settings => { max_threads => 1, max_memory_usage => 100 },
    settings         => { max_threads => 8 },
);
is %s<max_threads>, 8,                            'per-call setting wins over connection default';
is %s<max_memory_usage>, 100,                     'connection default survives';

my %p = build-query-params(database => 'db', params => { id => 42, name => "o'b" });
is %p<param_id>, '42',                            'param_ prefix';
is %p<param_name>, "o'b",                         'string param unquoted at top level';

# --- percent-encoding -------------------------------------------------------
is uri-escape('plain'),      'plain',             'unreserved characters survive';
is uri-escape('a b&c=d'),    'a%20b%26c%3Dd',     'separators are escaped';
is uri-escape('café'),       'caf%C3%A9',         'utf-8 is escaped bytewise';
