use strict;
use warnings;
use Setup;
use Test2::V0;

# A disposable PostgreSQL/Hydra context, never the production database.
my %ctx = test_init();
require Hydra::Plugin::S3Backup;
require Hydra::Event;
require Hydra::TaskDispatcher;
require Prometheus::Tiny::Shared;
require Nix::StorePath;

my $db = $ctx{context}->db;
my $rows = $db->resultset('TaskRetries');
my $path = Nix::StorePath->new('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-test-output');
my $drv = Nix::StorePath->new('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-test.drv');
{
    package Test::S3RetryBuild;
    sub buildstatus { 0; }
    sub job { 'test'; }
    sub id { 1; }
    sub drvpath { $drv; }
    sub buildoutputs { bless({}, 'Test::S3RetryOutput'); }
    sub finished { 0; }
    package Test::S3RetryOutput;
    sub path { $path; }
    package Test::S3RetryStore;
    sub queryPathInfo { ($drv); }
    sub isValidPath { 1; }
    sub computeFSClosure { ($path, $drv); }
}
my $build = bless({}, 'Test::S3RetryBuild');
my $plugin = Hydra::Plugin::S3Backup->new(db => $db, config => {s3backup => {
    jobs => 'nixpkgs:trunk:test', prefix => 'store/', backup_build_deps => 'true',
    check_endpoint => 'http://unused/check', publish_endpoint => 'http://unused/publish',
}});
my $dispatcher = Hydra::TaskDispatcher->new($db, Prometheus::Tiny::Shared->new, [$plugin],
    sub { $rows->save_task($_[0]); });
my ($response, $folder);
my @submitted_folders;
{
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { bless({}, 'Test::S3RetryStore'); };
    local *Hydra::Plugin::S3Backup::showJobName = sub { 'nixpkgs:trunk:test'; };
    local *Hydra::Plugin::S3Backup::_process_path_worker = sub {
        ($folder = $_[2]) =~ s{/nar$}{};
        (1, [{hash => substr("$path", 0, 32), info => "StorePath: /nix/store/$path\n"}]);
    };
    local *HTTP::Tiny::post = sub { push @submitted_folders, $folder; $response; };
    my $event = Hydra::Event->new_event('build_finished', '1');
    $event->{event}->{build} = $build;
    $response = {success => 0, status => 503, reason => 'test outage', content => ''};
    $dispatcher->dispatch_event($event);
    is($rows->count, 1, 'failed publication is persisted in TaskRetries');
    my $row = $rows->first;
    is($row->channel, 'build_finished', 'event channel survives persistence');
    is($row->pluginname, 'Hydra::Plugin::S3Backup', 'retry names the publication plugin');
    is($row->payload, '1', 'retry retains the exact event payload');
    is($row->attempts, 1, 'first failure has one attempt');
    ok(-d $folder, 'failed response retains sources that may already be queued');

    $row->update({retry_at => time() - 1});
    my $task = $rows->get_retryable_task;
    $task->{event}->{event}->{build} = $build;
    $dispatcher->dispatch_task($task);
    $row->discard_changes;
    is($rows->count, 1, 'failed retry does not lose its database record');
    is($row->attempts, 2, 'failed retry increments persisted attempts');
    ok($row->retry_at >= time(), 'failed retry is rescheduled with backoff');

    $row->update({retry_at => time() - 1});
    $task = $rows->get_retryable_task;
    $task->{event}->{event}->{build} = $build;
    $response = {success => 1, content => '{"success":true}'};
    $dispatcher->dispatch_task($task);
    is($rows->count, 0, 'accepted retry is deleted from the real database');
    ok(-d $folder, 'accepted spool remains available to the async publisher');
    File::Path::remove_tree(@submitted_folders);
}
done_testing;
