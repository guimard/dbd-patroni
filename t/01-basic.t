#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Test module loading
use_ok('DBD::Patroni');

# Test _is_readonly function
is(DBD::Patroni::_is_readonly('SELECT * FROM users'), 1, 'SELECT is readonly');
is(DBD::Patroni::_is_readonly('select id from users'), 1, 'select (lowercase) is readonly');
is(DBD::Patroni::_is_readonly('  SELECT * FROM users'), 1, 'SELECT with leading space is readonly');
is(DBD::Patroni::_is_readonly('WITH cte AS (SELECT 1) SELECT * FROM cte'), 1, 'WITH...SELECT is readonly');
is(DBD::Patroni::_is_readonly('INSERT INTO users (name) VALUES (?)'), 0, 'INSERT is not readonly');
is(DBD::Patroni::_is_readonly('UPDATE users SET name = ?'), 0, 'UPDATE is not readonly');
is(DBD::Patroni::_is_readonly('DELETE FROM users'), 0, 'DELETE is not readonly');
is(DBD::Patroni::_is_readonly('CREATE TABLE foo (id int)'), 0, 'CREATE is not readonly');
is(DBD::Patroni::_is_readonly('DROP TABLE foo'), 0, 'DROP is not readonly');
is(DBD::Patroni::_is_readonly(undef), 0, 'undef is not readonly');

# Test _select_replica function
my @replicas = (
    { host => 'replica1', port => 5432 },
    { host => 'replica2', port => 5432 },
    { host => 'replica3', port => 5432 },
);

# leader_only mode
is(DBD::Patroni::_select_replica(\@replicas, 'leader_only'), undef, 'leader_only returns undef');

# random mode (just check it returns something valid)
my $random = DBD::Patroni::_select_replica(\@replicas, 'random');
ok($random, 'random mode returns a replica');
ok(grep { $_ eq $random } @replicas, 'random returns one of the replicas');

# empty replicas
is(DBD::Patroni::_select_replica([], 'round_robin'), undef, 'empty replicas returns undef');
is(DBD::Patroni::_select_replica(undef, 'round_robin'), undef, 'undef replicas returns undef');

# round_robin mode
$DBD::Patroni::rr_idx = 0;
my $rr1 = DBD::Patroni::_select_replica(\@replicas, 'round_robin');
my $rr2 = DBD::Patroni::_select_replica(\@replicas, 'round_robin');
my $rr3 = DBD::Patroni::_select_replica(\@replicas, 'round_robin');
my $rr4 = DBD::Patroni::_select_replica(\@replicas, 'round_robin');

is($rr1->{host}, 'replica1', 'round_robin first call returns replica1');
is($rr2->{host}, 'replica2', 'round_robin second call returns replica2');
is($rr3->{host}, 'replica3', 'round_robin third call returns replica3');
is($rr4->{host}, 'replica1', 'round_robin fourth call wraps to replica1');

# Test _is_connection_error function
# Connection errors that should trigger rediscovery
is(DBD::Patroni::db::_is_connection_error('connection refused'), 1, 'connection refused is connection error');
is(DBD::Patroni::db::_is_connection_error('connection reset by peer'), 1, 'connection reset is connection error');
is(DBD::Patroni::db::_is_connection_error('could not connect to server'), 1, 'could not connect is connection error');
is(DBD::Patroni::db::_is_connection_error('server closed the connection unexpectedly'), 1, 'server closed is connection error');
is(DBD::Patroni::db::_is_connection_error('no connection to the server'), 1, 'no connection is connection error');
is(DBD::Patroni::db::_is_connection_error('terminating connection due to administrator command'), 1, 'terminating connection is connection error');
is(DBD::Patroni::db::_is_connection_error('connection timed out'), 1, 'connection timed out is connection error');
is(DBD::Patroni::db::_is_connection_error('lost connection to server'), 1, 'lost connection is connection error');

# Read-only errors (leader became replica after failover)
is(DBD::Patroni::db::_is_connection_error('cannot execute INSERT in a read-only transaction'), 1, 'read-only INSERT is connection error');
is(DBD::Patroni::db::_is_connection_error('cannot execute UPDATE in a read-only transaction'), 1, 'read-only UPDATE is connection error');
is(DBD::Patroni::db::_is_connection_error('cannot execute DELETE in a read-only transaction'), 1, 'read-only DELETE is connection error');
is(DBD::Patroni::db::_is_connection_error('ERROR: cannot execute TRUNCATE in a read-only transaction'), 1, 'read-only TRUNCATE is connection error');

# SQL errors that should NOT trigger rediscovery
is(DBD::Patroni::db::_is_connection_error('syntax error at or near "SELEC"'), 0, 'syntax error is not connection error');
is(DBD::Patroni::db::_is_connection_error('relation "nonexistent" does not exist'), 0, 'missing relation is not connection error');
is(DBD::Patroni::db::_is_connection_error('permission denied for table users'), 0, 'permission denied is not connection error');
is(DBD::Patroni::db::_is_connection_error('duplicate key value violates unique constraint'), 0, 'unique violation is not connection error');
is(DBD::Patroni::db::_is_connection_error(undef), 0, 'undef is not connection error');
is(DBD::Patroni::db::_is_connection_error(''), 0, 'empty string is not connection error');

done_testing();
