#!/usr/bin/perl -w

use 5.010;
use strict;
use warnings;

use lib 'lib';

use Test::More;
plan "no_plan";

BEGIN {
    eval "use Test::Exception";                 ## no critic
    plan skip_all => "because Test::Exception required for testing" if $@;
}

BEGIN {
    eval "use Test::RedisServer";               ## no critic
    plan skip_all => "because Test::RedisServer required for testing" if $@;
}

BEGIN {
    eval "use Net::EmptyPort";                  ## no critic
    plan skip_all => "because Net::EmptyPort required for testing" if $@;
}

use Redis::JobQueue qw(
    DEFAULT_SERVER
    DEFAULT_PORT
    DEFAULT_TIMEOUT

    STATUS_CREATED
    STATUS_WORKING
    STATUS_COMPLETED
    STATUS_DELETED

    ENOERROR
    EMISMATCHARG
    EDATATOOLARGE
    ENETWORK
    EMAXMEMORYLIMIT
    EMAXMEMORYPOLICY
    EJOBDELETED
    EREDIS
    );

my $redis;
my $real_redis;
my $port = Net::EmptyPort::empty_port( 32637 ); # 32637-32766 Unassigned

eval { $real_redis = Redis->new( server => DEFAULT_SERVER.":".DEFAULT_PORT ) };
if ( !$real_redis )
{
    $redis = eval { Test::RedisServer->new( conf => { port => $port }, timeout => 3 ) };
    if ( $redis )
    {
        eval { $real_redis = Redis->new( server => DEFAULT_SERVER.":".$port ) };
    }
}
my $skip_msg;
$skip_msg = "Redis server is unavailable" unless ( !$@ and $real_redis and $real_redis->ping );

SKIP: {
    diag $skip_msg if $skip_msg;
    skip( "Redis server is unavailable", 1 ) unless ( !$@ and $real_redis and $real_redis->ping );
$real_redis->quit;

my ( $jq, $job, @jobs, $maxmemory, $vm, $policy );
my $pre_job = {
    id           => '4BE19672-C503-11E1-BF34-28791473A258',
    queue        => 'lovely_queue',
    job          => 'strong_job',
    expire       => 60,
    status       => 'created',
    attribute    => scalar( localtime ),
    workload     => \'Some stuff up to 512MB long',
    result       => \'JOB result comes here, up to 512MB long',
    };

sub new_connect {
    # For real Redis:
#    $real_redis = Redis->new( server => DEFAULT_SERVER.":".DEFAULT_PORT );
#    $redis = $real_redis;
#    isa_ok( $redis, 'Redis' );

    # For Test::RedisServer
    $redis = Test::RedisServer->new( conf =>
        {
            port                => Net::EmptyPort::empty_port( 32637 ),
            maxmemory           => $maxmemory,
#            "vm-enabled"        => $vm,
            "maxmemory-policy"  => $policy,
            "maxmemory-samples" => 100,
        },
# Test::RedisServer does not use timeout = 0
        timeout => 3,
        );
    isa_ok( $redis, 'Test::RedisServer' );

    $jq = Redis::JobQueue->new(
        $redis,
        );
    isa_ok( $jq, 'Redis::JobQueue');

    $jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );
}

$maxmemory = 0;
$vm = "no";
$policy = "noeviction";
new_connect();

$jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );

$job = $jq->add_job( $pre_job );
isa_ok( $job, 'Redis::JobQueue::Job');

@jobs = $jq->get_jobs;
ok scalar( @jobs ), "jobs exists";

#-- ENOERROR

is $jq->last_errorcode, ENOERROR, "ENOERROR";
note '$@: ', $@;

#-- EMISMATCHARG

eval { $jq->load_job( undef ) };
is $jq->last_errorcode, EMISMATCHARG, "EMISMATCHARG";
note '$@: ', $@;

#-- EDATATOOLARGE

my $prev_max_datasize = $jq->max_datasize;
my $max_datasize = 100;
$pre_job->{result} .= '*' x ( $max_datasize + 1 );
$jq->max_datasize( $max_datasize );

$job = undef;
eval { $job = $jq->add_job( $pre_job ) };
is $jq->last_errorcode, EDATATOOLARGE, "EDATATOOLARGE";
note '$@: ', $@;
is $job, undef, "the job isn't changed";
$jq->max_datasize( $prev_max_datasize );

#-- ENETWORK

$job = $jq->add_job( $pre_job );
isa_ok( $job, 'Redis::JobQueue::Job');

$jq->quit;

@jobs = ();
eval { @jobs = $jq->get_jobs };
is $jq->last_errorcode, ENETWORK, "ENETWORK";
note '$@: ', $@;
ok !scalar( @jobs ), '@jobs is empty';
ok !$jq->_redis->ping, "server is not available";

new_connect();

#-- EMAXMEMORYLIMIT

SKIP:
{
    skip( 'because Test::RedisServer required for that test', 1 ) if eval { $real_redis->ping };

    $maxmemory = 1024 * 1024;
    new_connect();
    my ( undef, $max_datasize ) = $jq->_call_redis( 'CONFIG', 'GET', 'maxmemory' );
    is $max_datasize, $maxmemory, "value is set correctly";

    $pre_job->{result} .= '*' x 1024;
    for ( my $i = 0; $i < 1000; ++$i )
    {
        eval { $job = $jq->add_job( $pre_job ) };
        if ( $@ )
        {
            is $jq->last_errorcode, EMAXMEMORYLIMIT, "EMAXMEMORYLIMIT";
            note "($i)", '$@: ', $@;
            last;
        }
    }
    $jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );
}

#-- EMAXMEMORYPOLICY

SKIP:
{
    skip( 'because Test::RedisServer required for that test', 1 ) if eval { $real_redis->ping };

#    $policy = "volatile-lru";       # -> remove the key with an expire set using an LRU algorithm
#    $policy = "allkeys-lru";        # -> remove any key accordingly to the LRU algorithm
#    $policy = "volatile-random";    # -> remove a random key with an expire set
    $policy = "allkeys-random";     # -> remove a random key, any key
#    $policy = "volatile-ttl";       # -> remove the key with the nearest expire time (minor TTL)
#    $policy = "noeviction";         # -> don't expire at all, just return an error on write operations

    $maxmemory = 2 * 1024 * 1024;
    new_connect();
    my ( undef, $max_datasize ) = $jq->_call_redis( 'CONFIG', 'GET', 'maxmemory' );
    is $max_datasize, $maxmemory, "value is set correctly";

    $pre_job->{result} .= '*' x ( 1024 * 10 );
    $pre_job->{expire} = 0;

    {
        do
        {
            eval { $job = $jq->add_job( $pre_job ) } for ( 1..1024 );
        } until ( $jq->_call_redis( "KEYS", "JobQueue:queue:*" ) );

        eval {
            while ( my $job = $jq->get_next_job(
                queue       => $pre_job->{queue},
                blocking    => 1
                ) )
            {
                ;
            }
        };
        redo unless ( $jq->last_errorcode == EMAXMEMORYPOLICY );
    }
    ok $@, "exception";
    is $jq->last_errorcode, EMAXMEMORYPOLICY, "EMAXMEMORYPOLICY";
    note '$@: ', $@;

    $jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );
}

#-- EJOBDELETED

SKIP:
{
    skip( 'because Test::RedisServer required for that test', 1 ) if eval { $real_redis->ping };

    $policy = "noeviction";         # -> don't expire at all, just return an error on write operations

    $maxmemory = 1024 * 1024;
    new_connect();
    my ( undef, $max_datasize ) = $jq->_call_redis( 'CONFIG', 'GET', 'maxmemory' );
    is $max_datasize, $maxmemory, "value is set correctly";

# $jq->get_next_job after the jobs expired
    $pre_job->{result} .= '*' x 100;
    $pre_job->{expire} = 1;

    eval { $job = $jq->add_job( $pre_job ) } for ( 1..10 );
    my @jobs = $jq->get_jobs;
    ok scalar( @jobs ), "the jobs added";
    $jq->delete_job( $_ ) foreach @jobs;
    sleep $pre_job->{expire} * 2;
    my @new_jobs = $jq->get_jobs;
    ok !scalar( @new_jobs ), "the jobs expired";

    eval {
        while ( my $job = $jq->get_next_job(
            queue       => $pre_job->{queue},
            blocking    => 0
            ) )
        {
            ;
        }
    };
    is $@, "", "no exception";

# $jq->get_next_job before the jobs expired
    $pre_job->{expire} = 2;

    eval { $job = $jq->add_job( $pre_job ) } for ( 1..10 );
    @jobs = $jq->get_jobs;
    ok scalar( @jobs ), "the jobs added";
    $jq->delete_job( $_ ) foreach @jobs;

    eval {
        while ( my $job = $jq->get_next_job(
            queue       => $pre_job->{queue},
            blocking    => 0
            ) )
        {
            ;
        }
    };
    ok $@, "exception";
    is $jq->last_errorcode, EJOBDELETED, "EJOBDELETED";
    note '$@: ', $@;

    $jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );
}

#-- EREDIS

eval { $jq->_call_redis( "BADTHING", "Anything" ) };
is $jq->last_errorcode, EREDIS, "EREDIS";
note '$@: ', $@;

#-- Closes and cleans up -------------------------------------------------------

$jq->_call_redis( "DEL", $_ ) foreach $jq->_call_redis( "KEYS", "JobQueue:*" );

ok $jq->_redis->ping, "server is available";
$jq->quit;
ok !$jq->_redis->ping, "no server";

};

exit;
