#!/usr/bin/env raku
# Bulk insert with exact types, then read the rows back unchanged.
#
#   raku -Ilib examples/insert.raku [host] [port]
use lib $*PROGRAM.IO.parent(2).add('lib');
use ClickHouse;

my $ch = ClickHouse.new(
    host => (@*ARGS[0] // 'localhost'),
    port => (@*ARGS[1] // 8123).Int,
);

$ch.execute('DROP TABLE IF EXISTS raku_example_readings');
$ch.execute(q:to/SQL/);
    CREATE TABLE raku_example_readings (
        id      UInt64,
        sensor  String,
        at      DateTime,
        reading Decimal(38, 20),
        tags    Array(String),
        note    Nullable(String)
    ) ENGINE = MergeTree ORDER BY (sensor, at)
    SQL

my $now = DateTime.now;
$ch.insert('raku_example_readings', [
    [1, 'north',  $now,             '0.33333333333333333333'.FatRat, ['ok'],        'first'],
    [2, "o'hare", $now.later(:1minute), 1/3,                         ['ok', 'dup'], Str],
    [3, 'south',  $now.later(:2minute), -12.5,                       [],            'below zero'],
], columns => <id sensor at reading tags note>);

for $ch.query('SELECT * FROM raku_example_readings ORDER BY id').hashes -> %row {
    say sprintf '%d  %-8s %s  %-24s %-12s %s',
        %row<id>, %row<sensor>, %row<at>, %row<reading>.Str,
        %row<tags>.join(','), %row<note> // '(null)';
}

# The apostrophe went in as data, not SQL, and came back as data.
say '';
say 'parameter binding: ',
    $ch.query('SELECT count() FROM raku_example_readings WHERE sensor = {s:String}',
              params => { s => "o'hare" }).rows[0][0], ' row matches';

$ch.execute('DROP TABLE raku_example_readings');
