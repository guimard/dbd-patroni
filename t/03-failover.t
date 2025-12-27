#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Skip if not in integration test environment
unless ($ENV{PATRONI_URLS} && $ENV{TEST_FAILOVER}) {
    plan skip_all => 'PATRONI_URLS and TEST_FAILOVER not set, skipping failover tests';
}

use_ok('DBD::Patroni');
use LWP::UserAgent;
use JSON;

my $patroni_urls = $ENV{PATRONI_URLS};
my $user         = $ENV{PGUSER}     || 'testuser';
my $pass         = $ENV{PGPASSWORD} || 'testpass';
my $dbname       = $ENV{PGDATABASE} || 'testdb';

# Helper to get cluster info
sub get_cluster_info {
    my $ua = LWP::UserAgent->new(timeout => 5);

    for my $url (split /,/, $patroni_urls) {
        my $resp = $ua->get($url);
        next unless $resp->is_success;

        my $data = eval { decode_json($resp->decoded_content) };
        next unless $data && $data->{members};

        my ($leader) = grep { $_->{role} eq 'leader' } @{$data->{members}};
        my @replicas = grep { $_->{role} ne 'leader' } @{$data->{members}};

        return {
            leader   => $leader,
            replicas => \@replicas,
            members  => $data->{members},
        };
    }
    return undef;
}

# Helper to trigger failover via Patroni API
sub trigger_failover {
    my ($new_leader) = @_;

    my $ua = LWP::UserAgent->new(timeout => 10);

    # Find current leader's API endpoint
    my $info = get_cluster_info();
    return 0 unless $info && $info->{leader};

    my $leader_host = $info->{leader}{host};
    my $failover_url = "http://${leader_host}:8008/failover";

    my $resp = $ua->post(
        $failover_url,
        'Content-Type' => 'application/json',
        Content        => encode_json({ leader => $new_leader }),
    );

    return $resp->is_success;
}

# Test 1: Detect current leader
subtest 'Detect current leader' => sub {
    my $info = get_cluster_info();

    ok($info, 'Got cluster info');
    ok($info->{leader}, 'Found leader');
    ok(@{$info->{replicas}} >= 1, 'Found at least one replica');

    diag("Current leader: " . $info->{leader}{host});
    diag("Replicas: " . join(", ", map { $_->{host} } @{$info->{replicas}}));
};

# Test 2: Connection survives leader change
subtest 'Connection survives leader change' => sub {
    my $dbh = DBD::Patroni->connect(
        "dbname=$dbname",
        $user, $pass,
        { patroni_url => $patroni_urls }
    );

    ok($dbh, 'Initial connection');

    # Insert a test row
    my $name = "failover_test_" . time();
    $dbh->do("INSERT INTO users (name) VALUES (?)", undef, $name);

    # Get current leader
    my $info = get_cluster_info();
    my $old_leader = $info->{leader}{host};
    diag("Old leader: $old_leader");

    # Choose a new leader from replicas
    my @replicas = @{$info->{replicas}};
    skip "Need at least one replica for failover test", 3 unless @replicas;

    my $new_leader = $replicas[0]{name};
    diag("Triggering failover to: $new_leader");

    # Trigger failover
    my $failover_ok = trigger_failover($new_leader);
    ok($failover_ok, 'Failover triggered');

    # Wait for failover to complete
    diag("Waiting for failover to complete...");
    sleep 10;

    # Verify new leader
    $info = get_cluster_info();
    my $current_leader = $info->{leader}{host};
    diag("New leader: $current_leader");

    isnt($current_leader, $old_leader, 'Leader has changed');

    # Try to use the connection - it should auto-recover
    my $rv = eval {
        $dbh->do("INSERT INTO logs (message) VALUES (?)", undef, "After failover");
    };

    if ($@) {
        diag("First attempt failed (expected): $@");
        # The retry mechanism should kick in
        $rv = eval {
            $dbh->do("INSERT INTO logs (message) VALUES (?)", undef, "After failover retry");
        };
    }

    ok($rv, 'Write operation works after failover');

    # Read should also work
    my $sth = $dbh->prepare("SELECT message FROM logs ORDER BY id DESC LIMIT 1");
    $sth->execute;
    my ($msg) = $sth->fetchrow_array;

    like($msg, qr/After failover/, 'Read operation works after failover');

    $sth->finish;
    $dbh->disconnect;
};

# Test 3: New connection after failover
subtest 'New connection after failover' => sub {
    # Create a fresh connection after the failover
    my $dbh = eval {
        DBD::Patroni->connect(
            "dbname=$dbname",
            $user, $pass,
            { patroni_url => $patroni_urls }
        );
    };

    ok(!$@, 'New connection after failover') or diag("Error: $@");
    ok($dbh, 'Got database handle');

    # Verify read/write works
    my $name = "post_failover_" . time();
    $dbh->do("INSERT INTO users (name) VALUES (?)", undef, $name);

    sleep 1;

    my $sth = $dbh->prepare("SELECT name FROM users WHERE name = ?");
    $sth->execute($name);
    my ($result) = $sth->fetchrow_array;

    is($result, $name, 'Read/Write works on new connection');

    $sth->finish;
    $dbh->disconnect;
};

# Test 4: Verify cluster state
subtest 'Verify cluster state after tests' => sub {
    my $info = get_cluster_info();

    ok($info, 'Cluster is accessible');
    ok($info->{leader}, 'Cluster has a leader');

    my $running = grep { $_->{state} eq 'running' } @{$info->{members}};
    cmp_ok($running, '>=', 2, 'At least 2 nodes are running');

    diag("Final cluster state:");
    diag("  Leader: " . $info->{leader}{host});
    diag("  Running members: $running");
};

done_testing();
