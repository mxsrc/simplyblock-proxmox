package PVE::Storage::Custom::SimplyblockPlugin;

use strict;
use warnings;

use feature qw(fc);

use Data::Dumper;
use JSON;
use REST::Client;

use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

# Helpers
sub request {
    my ($scfg, $method, $path, $body) = @_;
    
    # TODO: Reuse client, place in $cache
    my $client = REST::Client->new({ follow => 1});
    $client->addHeader("Authorization", "$scfg->{cluster} $scfg->{secret}");
    $client->setHost($scfg->{entrypoint});

    if (defined $body) {
        $client->addHeader("Content-type", "application/json");
    }

    $client->request($method, $path, defined $body ? encode_json($body) : "");

    my $code = $client->responseCode();
    my $content = (fc($client->responseHeader('Content-type')) eq fc('application/json'))
        ? decode_json($client->responseContent())
        : ((200 <= $code or $code < 300)  # Ensure we always have response content
            ? { status => 1, results => 1 }
            : { status => 0 }
        );

    if (($code < 200 or 300 <= $code) or (not $content->{status})) {
        my $msg = exists $content->{error} ? $content->{error} : "-";
        warn("Request failed: $code, $msg");
        return;
    }

    return $content->{"results"};
}

sub list_nvme {
    my $json = '';

    eval {
    run_command(['nvme', 'list', '--output=json'],
        outfunc => sub { $json .= shift },
    );
    };

    return decode_json($json);
}

sub lvol_by_name {
    my ($scfg, $volname) = @_;
    my $lvols = request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");
    my ($lvol) = grep { $volname eq $_->{lvol_name} } @$lvols;
    return ($lvol->{id} or die("Volume not found\n"));
};

sub connect_lvol {
    my ($scfg, $id) = @_;
    my $connect_info = request($scfg, "GET", "/lvol/connect/$id");
    run_command(substr(@$connect_info[0]->{connect}, 5));
}


# Configuration
sub api {
	return 10;  # Only tested on this version so far.
}

sub type {
    return 'simplyblock';
}

sub plugindata {
    return {
        content => [
            { images => 1 },
            { images => 1 }
        ],
        format => [
            { raw => 1 },
            'raw'
        ],
    };
}

sub properties {
    return {
        entrypoint => {
            description => "Control plane server",
            type => 'string',
        },
        cluster => {
            description => "Cluster UUID",
            type => 'string',
        },
        secret => {
            description => "Cluster access token",
            type => 'string',
        },
    };
}

sub options {
    return {
        entrypoint => { optional => 0 },
        cluster => { optional => 0 },
        pool => { optional => 0 },
        secret => { optional => 0 },
    };
}

# Storage
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    request($scfg, "GET", "/cluster/$scfg->{cluster}") or die("Cluster not responding");
    my $lvols = request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");

    my $devices = list_nvme()->{Devices};

    foreach (@$lvols) {
        my $lvol = $_;

	    next if $lvol->{lvol_name} !~ m/^vm-(\d+)-/;

        # Skip already connected
        next if grep { $lvol->{id} eq $_->{ModelNumber} } @$devices;

        connect_lvol($scfg, $lvol->{id});
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # TODO: disconnect volumes?

    return 1;
}

sub status {
    # (total, avail, used, active) in KiB
    return (0, 0, 0, 0);
}

sub parse_volname {
    my ( $class, $volname ) = @_;

    if ($volname =~ m/^(vm-(\d+)-\S+)$/) {
        return ('images', $1, $2, undef, undef, 0, 'raw');
    }

    die "unable to parse lvm volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $id = lvol_by_name($scfg, $volname);  # TODO: Store name <> id mapping?
    my $devices = list_nvme()->{Devices};
    my ($device) = grep { $id eq $_->{ModelNumber} } @$devices;
    my $path = $device->{DevicePath};
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    die "create_base unimplemented";
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, "raw", 0);

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if  $name && $name !~ m/^vm-$vmid-/;

    request($scfg, "POST", "/lvol", {
        pool => $scfg->{pool},
        name => $name,
        size => $size * 1024,  # Size given in KiB
    }) or die("Failed to create image");

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $id = lvol_by_name($scfg, $volname);
    request($scfg, "DELETE", "/lvol/$id");

    return undef;
}

sub clone_image {
    die "clone_image unimplemented";
}

sub list_images {
    my ($class, $storeid, $scfg) = @_;

    my $lvols = request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");

    my $res = [];

    foreach (@$lvols) {
	    next if $_->{lvol_name} !~ m/^vm-(\d+)-/;

        push @$res, {
            volid => "$storeid:$_->{lvol_name}",
            format => 'raw',
            size => $_->{size},
            vmid => $1,
	    };
    }

    return $res;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $id = lvol_by_name($scfg, $volname);

    request($scfg, "PUT", "/lvol/resize/$id", {
        size => $size
    }) or die("Failed to resize image");
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume_snapshot unimplemented";
}

sub volume_snapshot_rollback {
    die "volume_snapshot_rollback unimplemented";
}

sub volume_snapshot_delete {
    die "volume_snapshot_delete unimplemented";
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $id = lvol_by_name($scfg, $source_volname);

    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, "raw")
        if !$target_volname;

    request($scfg, "PUT", "/lvol/resize/$id", {
        name => $target_volname
    }) or die("Failed to rename image");
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    return 1 if ($feature eq "sparseinit");

    die "unchecked feature '$feature'";
}

1;
