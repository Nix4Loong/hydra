# Native API and cache format integration without PostgreSQL, a daemon or networking.
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Which qw(which);
use Digest::SHA qw(sha256_hex);
use IPC::Run3 qw(run3);
use JSON::MaybeXS qw(decode_json);

my $tmp = tempdir(CLEANUP => 1);
my $store_dir = "$tmp/store";
local $ENV{NIX_STORE_DIR} = $store_dir;
local $ENV{NIX_STATE_DIR} = "$tmp/state";
local $ENV{NIX_LOG_DIR} = "$tmp/log";
local $ENV{NIX_REMOTE} = 'local';
local $ENV{NIX_CONF_DIR} = "$tmp/config";
local $ENV{NIX_USER_CONF_FILES} = '/dev/null';
make_path($ENV{NIX_CONF_DIR});
local $ENV{NIX_CONFIG} = "sandbox = false\nbuild-users-group =\nsubstituters =\nbuilders =\nexperimental-features = nix-command\n";
local $ENV{HYDRA_S3_TEST_SHELL} = which('bash') or die 'bash is required';

require Nix::Store;
require Hydra::StorePath;
require Hydra::Plugin::S3Backup;

sub command {
    my ($input, @cmd) = @_;
    my ($out, $err);
    run3(\@cmd, \$input, \$out, \$err);
    die "@cmd failed ($?): $err" if $?;
    return $out;
}
sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or die "$path: $!";
    binmode $fh;
    local $/;
    return <$fh>;
}
sub write_file {
    my ($path, $data) = @_;
    open(my $fh, '>', $path) or die "$path: $!";
    print $fh $data;
    close $fh or die "$path: $!";
}

my $fixture = "$tmp/jobs.nix";
write_file($fixture, <<'NIX');
let
  mk = attrs: derivation ({
    system = builtins.currentSystem;
    builder = builtins.getEnv "HYDRA_S3_TEST_SHELL";
    preferLocalBuild = true;
    allowSubstitutes = false;
  } // attrs);
  dependency = mk {
    name = "hydra-s3-native-dependency";
    outputs = [ "out" "info" "man" ];
    args = [ "-c" ''
      printf runtime > "$out"
      printf build-only-info > "$info"
      printf build-only-man > "$man"
    '' ];
  };
  root = mk {
    name = "hydra-s3-native-root";
    args = [ "-c" ''printf '%s' '${dependency.out}' > "$out"'' ];
  };
in { inherit root dependency; }
NIX
my $json = command(undef, 'nix', 'build', '--impure', '--file', $fixture, 'root', '--no-link', '--json');
my $built = decode_json($json)->[0];
my $root_full = $built->{outputs}->{out};
my $root_drv_full = $built->{drvPath};
my $outputs = decode_json(command(undef, 'nix', 'eval', '--impure', '--json', '--file', $fixture,
    '--apply', 'jobs: { out = jobs.dependency.out.outPath; info = jobs.dependency.info.outPath; man = jobs.dependency.man.outPath; }'));
my $store = Nix::Store->new();
is($store->storeDir, $store_dir, 'native store is the isolated temporary store');
my $root = Hydra::StorePath::parseStorePath($store_dir, $root_full);
my $root_drv = Hydra::StorePath::parseStorePath($store_dir, $root_drv_full);
my ($deriver, $nar_hash, undef, $nar_size, $refs) = $store->queryPathInfo($root, 1);
is(ref($deriver), 'Nix::StorePath', 'real XS returns a typed deriver');
is("$deriver", "$root_drv", 'real deriver identifies the built root');
is($nar_hash, $store->queryPathHash($root), 'queryPathInfo supplies the canonical base32 NAR hash');
my %runtime = map { ("$_", 1) } $store->computeFSClosure(0, 0, $root);
my %build_closure = map { ("$_", 1) } $store->computeFSClosure(0, 1, $root, $root_drv);
for my $name (qw(info man)) {
    my $path = Hydra::StorePath::parseStorePath($store_dir, $outputs->{$name});
    ok(!$runtime{"$path"}, "$name is absent from the runtime closure");
    ok($build_closure{"$path"}, "native build closure contains $name");
}

my $secret = command(undef, 'nix', 'key', 'generate-secret', '--key-name', 'hydra-s3-native-test');
my $public = command($secret, 'nix', 'key', 'convert-secret-to-public');
chomp($secret, $public);
my $cache = "$tmp/cache";
make_path("$cache/nar");
write_file("$cache/nix-cache-info", "StoreDir: $store_dir\nWantMassQuery: 1\nPriority: 50\n");
my $published;
{
    package Test::S3NativeOutput;
    sub path { $_[0]->{path} }
    package Test::S3NativeBuild;
    sub buildstatus { 0 }
    sub job { 'native' }
    sub id { 987654 }
    sub drvpath { $_[0]->{drv} }
    sub buildoutputs { bless({path => $_[0]->{path}}, 'Test::S3NativeOutput') }
    package Test::S3NativeHTTP;
    sub get { {success => 1, content => '{"exists":false}'} }
    sub post {
        my ($self, $url, $opts) = @_;
        $published = JSON::MaybeXS::decode_json($opts->{content});
        return {success => 1, content => '{"success":true}'};
    }
}
my $plugin = Hydra::Plugin::S3Backup->new(config => {s3backup => {
    jobs => 'nixpkgs:trunk:native', backup_build_deps => 'true',
    prefix => 'store/', check_endpoint => 'http://test.invalid/check',
    publish_endpoint => 'http://test.invalid/publish', secretKey => $secret,
}});
{
    no warnings qw(redefine once);
    local *Hydra::Plugin::S3Backup::machineLocalStore = sub { $store };
    local *Hydra::Plugin::S3Backup::showJobName = sub { 'nixpkgs:trunk:native' };
    local *HTTP::Tiny::new = sub { bless({}, 'Test::S3NativeHTTP') };
    $plugin->buildFinished(bless({path => $root, drv => $root_drv}, 'Test::S3NativeBuild'), []);
}
ok($published && @$published == 1, 'real plugin submits one publication manifest');
my $prepared = $published->[0]->{from};
for my $full ($root_full, @{$outputs}{qw(out info man)}) {
    my $path = Hydra::StorePath::parseStorePath($store_dir, $full);
    my $hash = substr "$path", 0, 32;
    my $narinfo = read_file("$prepared/$hash.narinfo");
    my %fields = map { split(/: /, $_, 2) } split(/\n/, $narinfo);
    is($fields{StorePath}, $full, "published path $path is full");
    my $compressed = read_file("$prepared/$fields{URL}");
    is($fields{FileHash}, 'sha256:' . sha256_hex($compressed), 'FileHash matches real compressed bytes');
    is($fields{FileSize}, length($compressed), 'FileSize matches real compressed bytes');
    my $nar = command(undef, 'zstd', '-q', '-d', '-c', "$prepared/$fields{URL}");
    is($fields{NarSize}, length($nar), 'NarSize matches the decompressed NAR');
    my $nar_path = "$tmp/current.nar";
    write_file($nar_path, $nar);
    my $actual_hash = command(undef, 'nix', 'hash', 'file', '--type', 'sha256', '--base32', $nar_path);
    chomp $actual_hash;
    is($fields{NarHash}, "sha256:$actual_hash", 'NarHash matches the decompressed NAR');
    like($fields{Sig}, qr/^hydra-s3-native-test:/, 'real Nix XS signs the NAR info');
    # Keep only these four outputs in the test cache, including every runtime reference.
    write_file("$cache/$hash.narinfo", $narinfo);
    write_file("$cache/$fields{URL}", $compressed);
}
my @paths = ($root_full, @{$outputs}{qw(out info man)});
command(undef, 'nix', 'store', 'verify', '--store', "file://$cache", '--sigs-needed', '1',
    '--option', 'trusted-public-keys', $public, @paths);
pass('Nix validates the real NAR bytes, hashes and signatures of every published output');
my ($stdout, $stderr);
run3(['nix', 'store', 'verify', '--store', "file://$cache", '--sigs-needed', '1',
    '--option', 'trusted-public-keys', '', @paths], \undef, \$stdout, \$stderr);
ok($? != 0, 'Nix rejects those signatures without the matching trusted public key');
# The plugin deliberately hands successful publication directories to sync4loong.
# This mocked publisher owns and cleans that directory in the isolated test.
File::Path::remove_tree($prepared);
done_testing;
