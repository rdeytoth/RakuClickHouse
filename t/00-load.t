use v6.d;
use Test;
use lib $?FILE.IO.parent(2).add('lib');

plan 5;

use-ok 'ClickHouse::Types',     'ClickHouse::Types loads';
use-ok 'ClickHouse::Transport', 'ClickHouse::Transport loads';
use-ok 'ClickHouse::Progress',  'ClickHouse::Progress loads';
use-ok 'ClickHouse',            'ClickHouse loads';

# The whole point of the rewrite: nothing outside JSON::Fast is required to
# talk plain HTTP to a server.
{
    use ClickHouse;
    ok ClickHouse.new(host => 'example.invalid') ~~ ClickHouse, 'can construct a handle';
}
