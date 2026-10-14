package Hydra::Plugin::S3Backup;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use File::Temp;
use Fcntl;
use IO::File;
use HTTP::Tiny;
use JSON::MaybeXS qw(decode_json encode_json);
use Digest::SHA;
use Nix::Store;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Nix;
use Hydra::StorePath;
use Hydra::View::NARInfo ();
use IPC::Run3;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{s3backup};
}

my $http_client;

my $lockfile = "/tmp/.hydra-s3backup.lock";

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    return $self->_processFinishedBuild($build, 0);
}

sub cachedBuildFinished {
    my ($self, $evaluation, $build) = @_;
    return $self->_processFinishedBuild($build, 1);
}

sub _processFinishedBuild {
    my ($self, $build, $is_cached) = @_;
    $is_cached //= 0;

    return unless $build->buildstatus == 0 or $build->buildstatus == 6;

    my $jobName = showJobName $build;
    my $job = $build->job;
    my $build_id = $build->id;

    if ($jobName =~ /runCommandHook/) {
        print STDERR "S3Backup: Skipping runCommandHook build $build_id for job '$jobName'\n";
        return;
    }

    print STDERR "S3Backup: Processing build $build_id for job '$jobName'\n";

    my $cfg = $self->{config}->{s3backup};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    # Find the first matching configuration (one-to-one matching)
    my $bucket_config;
    foreach my $config_item (@config) {
        if ($jobName =~ /^$config_item->{jobs}$/) {
            $bucket_config = $config_item;
            last;
        }
    }

    unless (defined $bucket_config) {
        print STDERR "S3Backup: No matching configuration for job '$jobName'\n";
        return;
    }

    if ($is_cached) {
        my $backup_cached_builds = 1;  # default to true to keep existing behavior
        if (exists $bucket_config->{backup_cached_builds}) {
            my $value = $bucket_config->{backup_cached_builds};
            $backup_cached_builds = !($value eq "0" || lc($value) eq "false" || lc($value) eq "no");
        }
        unless ($backup_cached_builds) {
            print STDERR "S3Backup: Skipping cached build $build_id for job '$jobName' as per configuration\n";
            return;
        }
    }

    unless (exists $bucket_config->{prefix} && defined $bucket_config->{prefix} && $bucket_config->{prefix} ne "") {
        die "S3Backup: prefix is required in configuration";
    }
    unless (exists $bucket_config->{publish_endpoint} && defined $bucket_config->{publish_endpoint} && $bucket_config->{publish_endpoint} ne "") {
        die "S3Backup: publish_endpoint is required in configuration";
    }
    unless (exists $bucket_config->{check_endpoint} && defined $bucket_config->{check_endpoint} && $bucket_config->{check_endpoint} ne "") {
        die "S3Backup: check_endpoint is required in configuration";
    }

    unless (defined $http_client) {
        $http_client = HTTP::Tiny->new(
            timeout => 30,
            agent => 'Hydra-S3Backup/1.0',
        );
    }

    # !!! Maybe should do per-bucket locking?
    my $lockhandle = IO::File->new;
    open($lockhandle, "+>", $lockfile) or die "Opening $lockfile: $!";
    flock($lockhandle, Fcntl::LOCK_SH) or die "Read-locking $lockfile: $!";

    # Collect initial paths from build outputs
    my @initial_paths = ();
    my %seen_outputs;
    foreach my $output ($build->buildoutputs) {
        my $p = $output->path;
        push @initial_paths, $p unless $seen_outputs{$p}++;
    }

    # Check if build dependencies backup is enabled
    my $backup_build_deps = 0;  # default to false
    if (exists $bucket_config->{backup_build_deps}) {
        my $value = $bucket_config->{backup_build_deps};
        $backup_build_deps = ($value eq "1" || lc($value) eq "true" || lc($value) eq "yes") ? 1 : 0;
    }

    # Step 1: Get derivation paths for build outputs and add them to initial_paths
    if ($backup_build_deps) {
        my %initial_paths_set = map { $_ => 1 } @initial_paths;  # Create set for deduplication

        my @output_paths = @initial_paths;
        foreach my $initial_path (@output_paths) {
            my $drv_path;
            eval {
                ($drv_path) = machineLocalStore()->queryPathInfo($initial_path, 1);
                1;
            } or die "S3Backup: Cannot query deriver for $initial_path: $@";
            if (!defined($drv_path) || !machineLocalStore()->isValidPath($drv_path)) {
                $drv_path = $build->drvpath;
            }
            die "S3Backup: No valid derivation for build $build_id output $initial_path\n"
                unless defined($drv_path) && machineLocalStore()->isValidPath($drv_path);
            if (!exists $initial_paths_set{$drv_path}) {
                push @initial_paths, $drv_path;
                $initial_paths_set{$drv_path} = 1;
            }
        }
    }

    # The binding accepts and returns Nix::StorePath objects. Keep them typed
    # until a path crosses the CLI or narinfo boundary.
    my %all_paths;
    eval {
        %all_paths = map { $_ => $_ } machineLocalStore()->computeFSClosure(0, 1, @initial_paths);
        1;
    } or die "S3Backup: Cannot query closure for build $build_id: $@";

    my $exclude_self = 0;  # default to false
    if (exists $bucket_config->{exclude_self}) {
        my $value = $bucket_config->{exclude_self};
        $exclude_self = ($value eq "1" || lc($value) eq "true" || lc($value) eq "yes") ? 1 : 0;
    }
    if ($exclude_self) {
        foreach my $initial_path (@initial_paths) {
            delete $all_paths{$initial_path};
        }
    }

    # Failed preparation/no-op attempts can clean up immediately. Once POST
    # is attempted, sync4loong may have queued files even if the response
    # fails, so retain that source directory for its asynchronous workers.
    my $publish_dir = File::Temp->newdir("s3-backup-publish-$build_id" . "XXXXX", TMPDIR => 1, CLEANUP => 1);
    my $publish_path = $publish_dir->dirname;
    my $nar_dir = "$publish_path/nar";
    mkdir($nar_dir) or die "Cannot create nar directory $nar_dir: $!";

    # Process all paths sequentially
    my @all_narinfos = ();
    my $processed_paths = 0;
    my @errors = ();

    foreach my $path (values %all_paths) {
        next if $path =~ /\.drv$/;  # Skip .drv files
        my ($path_processed, $path_narinfos) = _process_path_worker($path, $bucket_config, $nar_dir, $build_id, \@errors);
        if (defined $path_processed && defined $path_narinfos && ref($path_narinfos) eq 'ARRAY') {
            $processed_paths += $path_processed;
            push @all_narinfos, @$path_narinfos;
        }
    }

    # Check for any errors
    if (@errors) {
        print STDERR "S3Backup: " . scalar(@errors) . " errors occurred during processing:\n";
        foreach my $error (@errors) {
            print STDERR "S3Backup: $error\n";
        }
        die "S3Backup: Processing failed with errors";
    }

    my $prepared_narinfos = 0;
    foreach my $info (@all_narinfos) {
        my $narinfo_dest = "$publish_path/" . $info->{hash} . ".narinfo";
        unless (-f $narinfo_dest) {
            if (open(my $fh, '>', $narinfo_dest)) {
                print $fh $info->{info};
                close($fh);
                $prepared_narinfos++;
            } else {
                print STDERR "S3Backup: Failed to write narinfo file: $narinfo_dest\n";
                die;
            }
        }
    }

    # Publish all files via HTTP request
    if ($prepared_narinfos > 0 || $processed_paths > 0) {
        my $prefix = $bucket_config->{prefix};
        my $publish_endpoint = $bucket_config->{publish_endpoint};

        my $publish_data = [
            {
                from => $publish_path,
                to => $prefix,
                delete_after_sync => JSON::MaybeXS::true,
                unique => JSON::MaybeXS::true
            }
        ];

        my $json_payload = encode_json($publish_data);

        print STDERR "S3Backup: Publishing to $publish_endpoint with prefix: '$prefix', folder: $publish_path\n";

        $publish_dir->unlink_on_destroy(0);
        my $response = $http_client->post($publish_endpoint, {
            headers => {
                'Content-Type' => 'application/json',
            },
            content => $json_payload,
        });

        if ($response->{success}) {
            eval {
                my $response_data = decode_json($response->{content});
                if ($response_data->{success}) {
                    # sync4loong owns cleanup after the queued file transfers.
                } else {
                    my $error_msg = $response_data->{message} // "Unknown error";
                    print STDERR "S3Backup: Publish request failed: $error_msg\n";
                    die "S3Backup: Publish request failed: $error_msg";
                }
            };
            if ($@) {
                print STDERR "S3Backup: Failed to parse publish response: $@\n";
                print STDERR "S3Backup: Response content: " . $response->{content} . "\n";
                die "S3Backup: Failed to parse publish response";
            }
        } else {
            print STDERR "S3Backup: Failed to publish: HTTP " . $response->{status} . " - " . $response->{reason} . "\n";
            if ($response->{content}) {
                print STDERR "S3Backup: Response content: " . $response->{content} . "\n";
            }
            die "S3Backup: Failed to publish files";
        }
    } else {
        print STDERR "S3Backup: Build $build_id - no files need to be published\n";
    }
}

sub _process_path_worker {
    my ($path, $bucket_config, $nar_dir, $build_id, $errors) = @_;
    my @local_narinfos = ();
    my $local_processed = 0;

    # Create HTTP client
    my $local_http_client = HTTP::Tiny->new(
        timeout => 30,
        agent => 'Hydra-S3Backup/1.0',
    );

    eval {
        my $storeDir = machineLocalStore()->storeDir;
        my $fullPath = printStorePath($storeDir, $path);
        my $hash = substr $path->to_string, 0, 32;

        my ($deriver, $narHash, $time, $narSize, $refs) = machineLocalStore()->queryPathInfo($path, 1);

        # Check if this path already exists via HTTP endpoint
        my $prefix = $bucket_config->{prefix};
        my $key = $prefix . "$hash.narinfo";
        my $check_url = $bucket_config->{check_endpoint} . "?key=" . $key;
        my $should_skip = 0;
        my $response = $local_http_client->get($check_url);
        if ($response->{success}) {
            eval {
                my $json_data = decode_json($response->{content});
                if ($json_data->{exists}) {
                    $should_skip = 1;
                }
            };
            if ($@) {
                print STDERR "S3Backup: Warning - failed to parse check response for $key: $@\n";
            }
        } else {
            print STDERR "S3Backup: Warning - failed to check existence of $key: " . $response->{reason} . "\n";
        }
        return (0, []) if $should_skip;

        # Only skip confirmed FODs. A missing deriver cannot classify a valid
        # output, so back it up; CLI/JSON failures for an available deriver
        # fail the task instead of silently losing an otherwise normal output.
        return (0, []) if _is_fixed_output_derivation($path, $deriver);

        # FIXME: Very hacky, but we don't want to backup the NixOS ISOs
        return (0, []) if ($path =~ /nixos-/ and $path =~ /loongarch64-linux\.iso/);

        # Create temp directory
        my $tempdir = File::Temp->newdir("s3-backup-temp-XXXXX", TMPDIR => 1);

        # Create NAR file
        run3(['nix', '--extra-experimental-features', 'nix-command', 'store', 'dump-path', $fullPath],
            \undef, "$tempdir/nar", \undef);
        if ($? != 0) {
            die "Failed to create NAR for $path";
        }
        # Compress with zstd at high compression level
        if (system("zstd -T0 -q -z '$tempdir/nar' -o '$tempdir/nar.zst'") != 0) {
            die "Failed to compress NAR for $path";
        }

        my $system;
        if (defined $deriver and machineLocalStore()->isValidPath($deriver)) {
            eval {
                $system = machineLocalStore()->derivationSystem($deriver);
            };
            if ($@) {
                print STDERR "S3Backup: Warning - failed to get derivation info for $deriver: $@\n";
            }
        }

        my $digest = Digest::SHA->new(256);
        $digest->addfile("$tempdir/nar.zst");
        my $file_hash = $digest->hexdigest;
        my @stats = stat "$tempdir/nar.zst" or die "Couldn't stat $tempdir/nar.zst";
        my $file_size = $stats[7];

        my $narinfo = "";
        $narinfo .= "StorePath: $fullPath\n";
        $narinfo .= "URL: nar/$hash.nar.zst\n";
        $narinfo .= "Compression: zstd\n";
        $narinfo .= "FileHash: sha256:$file_hash\n";
        $narinfo .= "FileSize: $file_size\n";
        $narinfo .= "NarHash: $narHash\n";
        $narinfo .= "NarSize: $narSize\n";
        $narinfo .= "References: " . join(" ", map { $_->to_string } @{$refs}) . "\n";
        if (defined $deriver) {
            $narinfo .= "Deriver: " . $deriver->to_string . "\n";
            if (defined $system) {
                $narinfo .= "System: $system\n";
            }
        }

        if (exists $bucket_config->{secretKey} && defined $bucket_config->{secretKey}) {
            my $secretKey = $bucket_config->{secretKey};
            my $fingerprint = Hydra::View::NARInfo::fingerprintPath($storeDir, $path, $narHash, $narSize, $refs);
            my $sig = signString($secretKey, $fingerprint);
            $narinfo .= "Sig: $sig\n";
        }

        push @local_narinfos, { hash => $hash, info => $narinfo };

        # Move compressed file to final location
        my $nar_dest = "$nar_dir/$hash.nar.zst";
        unless (-f $nar_dest) {
            if (system("mv", "$tempdir/nar.zst", $nar_dest) != 0) {
                die "Failed to move compressed NAR file to publish directory: $nar_dest";
            }
        }

        $local_processed++;
        print STDERR "S3Backup: Processed $path\n";
    };
    if ($@) {
        push @$errors, "Error processing $path: $@";
        print STDERR "S3Backup: Error processing $path: $@\n";
    }

    return ($local_processed, \@local_narinfos);
}

sub _is_fixed_output_derivation {
    my ($path, $deriver) = @_;
    unless (defined($deriver) && machineLocalStore()->isValidPath($deriver)) {
        print STDERR "S3Backup: No available deriver for $path; backing up unclassified output\n";
        return 0;
    }

    my $fullDrv = printStorePath(machineLocalStore()->storeDir, $deriver);
    my ($json, $stderr);
    run3(['nix', '--extra-experimental-features', 'nix-command', 'derivation', 'show', $fullDrv],
        \undef, \$json, \$stderr);
    die "Cannot inspect derivation $fullDrv (status $?); $stderr" if $? != 0;
    my $data = decode_json($json);
    die "Invalid derivation JSON for $fullDrv" unless ref($data) eq 'HASH';
    $data = $data->{derivations} if exists $data->{derivations};
    die "Expected one derivation for $fullDrv"
        unless ref($data) eq 'HASH' && keys(%$data) == 1;
    my ($drv) = values %$data;
    die "Invalid outputs for $fullDrv"
        unless ref($drv) eq 'HASH' && ref($drv->{outputs}) eq 'HASH' && keys(%{$drv->{outputs}});
    my $is_fod = 1;
    foreach my $output (values %{$drv->{outputs}}) {
        die "Invalid output for $fullDrv" unless ref($output) eq 'HASH';
        $is_fod = 0 unless defined($output->{hash}) && $output->{hash} ne '';
    }
    return $is_fod;
}

1;
