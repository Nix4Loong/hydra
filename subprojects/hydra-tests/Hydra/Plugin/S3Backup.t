use strict;
use warnings;
use Test2::V0;
use Hydra::Plugin::S3Backup;
use Nix::StorePath;
use Hydra::View::NARInfo;
use File::Temp qw(tempdir);
use JSON::MaybeXS qw(decode_json encode_json);
use File::Path qw(remove_tree);

my $output = Nix::StorePath->new('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-output');
my $drv = Nix::StorePath->new('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-root.drv');
my $info = Nix::StorePath->new('cccccccccccccccccccccccccccccccc-xgcc-info');
my $missing = Nix::StorePath->new('dddddddddddddddddddddddddddddddd-collected.drv');

{
    package Test::S3Store;
    sub queryPathInfo {
        my ($self, $path, $base32) = @_;
        die "API failure\n" if $self->{fail_api};
        die "expected typed output" unless ref($path) eq 'Nix::StorePath' && $path !~ /\.drv$/;
        die "expected base32 hash" unless $base32;
        $self->{queries}{$path}++;
        return ($self->{deriver});
    }
    sub isValidPath { $_[1] eq $drv; }
    sub computeFSClosure {
        my ($self, $flip, $include_outputs, @roots) = @_;
        die "closure failure\n" if $self->{fail_closure};
        die "wrong closure flags" unless $flip == 0 && $include_outputs == 1;
        die "lost StorePath type" if grep { ref($_) ne 'Nix::StorePath' } @roots;
        return (@roots, (grep { $_ eq $drv } @roots) ? ($info) : ());
    }
    package Test::S3Output;
    sub path { $_[0]->{path} // $output; }
    package Test::S3Build;
    sub buildstatus { $_[0]->{status} // 0; }
    sub job { 'test'; }
    sub id { 1; }
    sub drvpath { $_[0]->{drv}; }
    sub buildoutputs { map { bless({path => $_}, 'Test::S3Output') } @{$_[0]->{outputs} // [$output]}; }
    sub finished { 0; }
}

my $store = bless({deriver => $drv}, 'Test::S3Store');
my $build = bless({drv => $drv}, 'Test::S3Build');
my $config = {
    jobs => 'nixpkgs:trunk:test', backup_build_deps => 'true',
    prefix => 'store/', check_endpoint => 'http://unused/check',
    publish_endpoint => 'http://unused/publish', backup_cached_builds => 'false',
};
my $plugin = Hydra::Plugin::S3Backup->new(config => {s3backup => $config});
my %seen;
{
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { $store; };
    local *Hydra::Plugin::S3Backup::showJobName = sub { 'nixpkgs:trunk:test'; };
    local *Hydra::Plugin::S3Backup::_process_path_worker = sub {
        die 'worker needs a StorePath' unless ref($_[0]) eq 'Nix::StorePath';
        $seen{$_[0]}++;
        return (0, []);
    };

    $plugin->buildFinished($build, []);
    ok($seen{$info}, 'build-only output is included with the new bindings');
    is($seen{$info}, 1, 'paths are deduplicated');

    for my $deriver (undef, $missing) {
        $store->{deriver} = $deriver;
        %seen = ();
        $plugin->buildFinished($build, []);
        ok($seen{$info}, 'missing or invalid deriver falls back to build drv');
    }

    $build->{drv} = $missing;
    like(dies { $plugin->buildFinished($build, []); }, qr/No valid derivation/,
        'missing derivation fails rather than publishing an incomplete closure');
    $build->{drv} = $drv;

    $store->{fail_api} = 1;
    like(dies { $plugin->buildFinished($build, []); }, qr/Cannot query deriver.*API failure/s,
        'API errors reach the task retry mechanism');
    delete $store->{fail_api};
    $store->{deriver} = $drv;

    $store->{fail_closure} = 1;
    %seen = ();
    like(dies { $plugin->buildFinished($build, []); }, qr/Cannot query closure.*closure failure/s,
        'closure errors reach the task retry mechanism');
    is(scalar keys %seen, 0, 'nothing is published after closure enumeration fails');
    delete $store->{fail_closure};

    $plugin->cachedBuildFinished(undef, $build);
    is(scalar keys %seen, 0, 'cached-build skip policy is preserved');

    $config->{backup_build_deps} = 'false';
    $plugin->buildFinished($build, []);
    ok($seen{$output}, 'runtime output is still processed without build deps');
    ok(!$seen{$info}, 'build-only output is excluded when configured');
}

my $hash = 'sha256:' . ('0' x 52);
is(Hydra::View::NARInfo::fingerprintPath('/nix/store', $output, $hash, 123, [$info]),
    "1;/nix/store/$output;$hash;123;/nix/store/$info",
    'signature fingerprint retains full paths and a base32 NAR hash');

{
    package Test::S3WorkerStore;
    sub storeDir { '/nix/store'; }
    sub queryPathInfo { ($drv, $hash, 0, 123, [$info]); }
    sub isValidPath { 1; }
    sub derivationSystem { 'loongarch64-linux'; }
    package Test::S3HTTP;
    sub get { {success => 1, content => '{"exists":false}'}; }
}

my $tmp = tempdir(CLEANUP => 1);
my $fingerprint;
my @errors;
{
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { bless({}, 'Test::S3WorkerStore'); };
    local *HTTP::Tiny::new = sub { bless({}, 'Test::S3HTTP'); };
    local *Hydra::Plugin::S3Backup::run3 = sub {
        my ($cmd, $stdin, $dest) = @_;
        if ($cmd->[3] eq 'derivation') {
            is($cmd->[-1], "/nix/store/$drv", 'FOD detection receives the full deriver path');
            $$dest = '{"derivations":{"test.drv":{"outputs":{"out":{}}}}}';
            $? = 0;
            return 1;
        }
        is($cmd->[-1], "/nix/store/$output", 'dump-path receives the full path');
        open(my $fh, '>', $dest) or die $!;
        print $fh 'test NAR';
        close $fh;
        $? = 0;
        return 1;
    };
    local *Hydra::Plugin::S3Backup::signString = sub { $fingerprint = $_[1]; 'cache:test-signature'; };
    my ($count, $narinfos) = Hydra::Plugin::S3Backup::_process_path_worker(
        $output, {%$config, secretKey => 'test-only'}, $tmp, 1, \@errors);
    is(\@errors, [], 'worker succeeds with the new store-path API');
    is($count, 1, 'worker prepares one NAR');
    my $narinfo = $narinfos->[0]->{info};
    like($narinfo, qr{^StorePath: /nix/store/\Q$output\E$}m, 'narinfo StorePath is full');
    like($narinfo, qr{^References: \Q$info\E$}m, 'narinfo References are bare names');
    like($narinfo, qr{^Deriver: \Q$drv\E$}m, 'narinfo Deriver is a bare name');
    like($narinfo, qr/^System: loongarch64-linux$/m, 'worker uses derivationSystem');
    like($narinfo, qr/^Sig: cache:test-signature$/m, 'narinfo is signed');
    is($fingerprint, "1;/nix/store/$output;$hash;123;/nix/store/$info",
        'worker signs the canonical full-path fingerprint');
}

subtest 'multiple outputs, filtering and cached policy' => sub {
    my $second = Nix::StorePath->new('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-second');
    my $same_output = Nix::StorePath->new($output->to_string);
    local $build->{outputs} = [$output, $same_output, $second];
    local $config->{backup_build_deps} = 'true';
    local $store->{queries} = {};
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { $store; };
    local *Hydra::Plugin::S3Backup::showJobName = sub { 'nixpkgs:trunk:test'; };
    local *Hydra::Plugin::S3Backup::_process_path_worker = sub { $seen{$_[0]}++; (0, []); };
    %seen = ();
    $plugin->buildFinished($build, []);
    is([sort keys %seen], [sort map { "$_" } ($output, $second, $info)],
        'distinct outputs and build-only dependency are processed once');
    is($store->{queries}{$output}, 1, 'equivalent output objects are deduplicated before querying');
    is($store->{queries}{$second}, 1, 'second output deriver is queried');

    local $config->{exclude_self} = 'true';
    %seen = ();
    $plugin->buildFinished($build, []);
    is([keys %seen], ["$info"], 'exclude_self removes outputs but retains build-only dependencies');

    for my $value ('false', '0', 'no', 'NO') {
        local $config->{backup_cached_builds} = $value;
        %seen = ();
        $plugin->cachedBuildFinished(undef, $build);
        is(scalar keys %seen, 0, "cached skip policy: $value");
    }
    for my $value ('true', '1', 'yes', undef) {
        local $config->{backup_cached_builds} = $value;
        delete $config->{backup_cached_builds} unless defined $value;
        %seen = ();
        $plugin->cachedBuildFinished(undef, $build);
        ok($seen{$info}, 'cached builds publish when enabled or unspecified');
    }
    for my $status (1, 2, 3, 4) {
        local $build->{status} = $status;
        %seen = ();
        $plugin->buildFinished($build, []);
        is(scalar keys %seen, 0, "failed build status $status is skipped");
    }
    local $build->{status} = 6;
    %seen = ();
    $plugin->buildFinished($build, []);
    ok($seen{$info}, 'successful build with failed checks is still backed up');
};

subtest 'FOD classification never hides query errors' => sub {
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { bless({}, 'Test::S3WorkerStore'); };
    my ($json, $status, $calls) = ('', 0, 0);
    local *Hydra::Plugin::S3Backup::run3 = sub {
        my ($cmd, $stdin, $stdout, $stderr) = @_;
        $calls++;
        $$stdout = $json;
        $$stderr = 'test CLI error';
        $? = $status;
        1;
    };
    for my $wrapped (0, 1) {
        for my $fod (0, 1) {
            my $data = {'test.drv' => {outputs => {out => $fod ? {hash => 'abc'} : {path => '/nix/store/test'}}}};
            $json = encode_json($wrapped ? {derivations => $data} : $data);
            is(Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, $drv), $fod,
                'legacy/new JSON preserves FOD classification');
        }
    }
    $json = encode_json({derivations => {'test.drv' => {outputs => {out => {hash => 'abc'}, dev => {}}}}});
    ok(!Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, $drv), 'mixed outputs are not classified as FOD');
    $status = 256;
    like(dies { Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, $drv); },
        qr/Cannot inspect derivation.*test CLI error/s, 'CLI failure fails instead of skipping the path');
    $status = 0;
    for my $bad ('invalid JSON', '{}', '{"derivations":{}}', '{"derivations":{"test.drv":{"outputs":{}}}}') {
        $json = $bad;
        ok(dies { Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, $drv); },
            'invalid or incomplete metadata fails instead of silently classifying');
    }
    $calls = 0;
    ok(!Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, undef),
        'unknown deriver is backed up rather than silently assumed FOD');
    is($calls, 0, 'unknown deriver does not invoke an impossible CLI lookup');
    local *Test::S3WorkerStore::isValidPath = sub { 0; };
    ok(!Hydra::Plugin::S3Backup::_is_fixed_output_derivation($output, $missing),
        'collected deriver is also backed up');
};

subtest 'publication failures and dispatcher retries' => sub {
    require Hydra::Event;
    require Hydra::TaskDispatcher;
    require Prometheus::Tiny;
    local $config->{backup_build_deps} = 'true';
    local $config->{exclude_self} = 'false';
    no warnings 'redefine';
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { $store; };
    local *Hydra::Plugin::S3Backup::showJobName = sub { 'nixpkgs:trunk:test'; };
    my ($response, $folder, $posts, $worker_error) = (undef, undef, 0, 0);
    my @submitted_folders;
    local *Hydra::Plugin::S3Backup::_process_path_worker = sub {
        my ($path, $cfg, $nar_dir, $id, $errors) = @_;
        ($folder = $nar_dir) =~ s{/nar$}{};
        if ($worker_error) { push @$errors, 'test worker failed'; return (0, []); }
        (1, [{hash => substr("$path", 0, 32), info => "StorePath: /nix/store/$path\n"}]);
    };
    local *HTTP::Tiny::post = sub {
        my ($http, $url, $args) = @_;
        $posts++;
        push @submitted_folders, $folder;
        is($url, $config->{publish_endpoint}, 'uses configured publication endpoint');
        my $manifest = decode_json($args->{content});
        is($manifest->[0]->{to}, 'store/', 'publication prefix is preserved');
        is($manifest->[0]->{from}, $folder, 'manifest names the prepared folder');
        ok($manifest->[0]->{delete_after_sync}, 'sync4loong owns cleanup after acceptance');
        my @files = glob "$folder/*.narinfo";
        is(scalar @files, 2, 'all root and build-only narinfos are staged before POST');
        $response;
    };
    for my $failure (
        {success => 0, status => 503, reason => 'offline', content => ''},
        {success => 0, status => 599, reason => 'timeout after enqueue', content => ''},
        {success => 1, content => '{"success":false,"message":"denied"}'},
        {success => 1, content => 'invalid JSON'},
    ) {
        $response = $failure;
        ok(dies { $plugin->buildFinished($build, []); }, 'HTTP/JSON/business failure fails publication');
        ok(-d $folder, 'ambiguous HTTP failure retains sources that may already be queued');
        my @queued_files = glob "$folder/*.narinfo";
        is(scalar @queued_files, 2, 'queued sources remain readable after the failed response');
    }
    $posts = 0;
    $worker_error = 1;
    ok(dies { $plugin->buildFinished($build, []); }, 'worker failure fails whole publication');
    is($posts, 0, 'partial worker results are not sent');
    ok(!-d $folder, 'worker failure removes its unpublished spool');
    $worker_error = 0;

    my $event = Hydra::Event->new_event('build_finished', '1');
    $event->{event}->{build} = $build;
    my @stored;
    my $dispatcher = Hydra::TaskDispatcher->new(undef, Prometheus::Tiny->new, [$plugin], sub { push @stored, $_[0]; });
    $response = {success => 0, status => 503, reason => 'offline', content => ''};
    $dispatcher->dispatch_event($event);
    is(scalar @stored, 1, 'actual dispatcher hands failed plugin task to retry storage');
    my $task = $stored[0];
    my $record = bless({}, 'Test::S3RetryRecord');
    $task->{record} = $record;
    $dispatcher->dispatch_task($task);
    is($record->{requeued}, 1, 'failed retry is requeued');
    ok(!$record->{deleted}, 'failed retry remains recorded');
    $response = {success => 1, content => '{"success":true}'};
    $dispatcher->dispatch_task($task);
    is($record->{deleted}, 1, 'accepted retry is cleared by the actual dispatcher');
    ok(-d $folder, 'accepted spool remains available for async sync4loong');
    remove_tree(@submitted_folders);
};

{
    package Test::S3RetryRecord;
    sub attempts { 1; }
    sub requeue { $_[0]->{requeued}++; }
    sub delete { $_[0]->{deleted}++; }
}

done_testing;
