package App::MTPUtils;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'CLI utilities related to MTP (Media Transfer Protocol)',
};

my $out_name = "mtp-files.out";

my $err_no_mtp_files_out = [412, "No $out_name present, please create it first using 'mtp-files > $out_name'"];

sub _parse_mtp_files_output {
    (-f $out_name) or return undef;
    open my($fh), "<", $out_name or die "Can't open '$out_name': $!";
    my %files_by_id; # key: id, value: {name=>..., size=>..., pid=>...}
    my %files_by_name; # key: name, value: [id, ...]
    my $cur_file;
    my $code_add_file = sub {
        my $file = shift or return;
        $files_by_id{$file->{id}} = $file;
        $files_by_name{$file->{name}} //= [];
        push @{ $files_by_name{$file->{name}} }, $file->{id};
    };
    while (defined(my $line = <$fh>)) {
        if ($line =~ /^File ID: (\d+)/) {
            $code_add_file->($cur_file);
            $cur_file = {id=>$1};
            next;
        }
        if (defined $cur_file) {
            if ($line =~ /^\s+Filename: (.+)/) {
                $cur_file->{name} = $1;
            } elsif ($line =~ /^\s+File size (\d+)/) {
                $cur_file->{size} = $1;
            } elsif ($line =~ /^\s+Parent ID: (\d+)/) {
                $cur_file->{pid} = $1;
            }
        }
    }
    $code_add_file->($cur_file);
    #use DD; dd \%files_by_id; dd \%files_by_name;
    return [\%files_by_id, \%files_by_name];
}

sub _complete_filename_or_id {
    require Complete::Util;
    my %args = @_;

    my $parse_res = _parse_mtp_files_output() or return undef;

    my ($files_by_id, $files_by_name) = @$parse_res;

    Complete::Util::complete_array_elem(
        %args,
        array => [keys(%$files_by_id), keys(%$files_by_name)],
    );
}

$SPEC{list_files} = {
    v => 1.1,
    summary => 'List files contained in mtp-files.out',
    description => <<'_',

This routine will present information in `mtp-files.out` in a more readable way,
like the Unix `ls` command.

To use this routine, you must already run `mtp-files` and save its output in
`mtp-files.out` file, e.g.:

    % mtp-files > mtp-files.out

_
    args => {
        queries => {
            summary => 'Filenames/wildcards',
            'summary.alt.plurality.singular' => 'Filename/wildcard',
            'x.name.is_plural' => 1,
            schema => ['array*', of=>'str*'],
            pos => 0,
            greedy => 1,
            element_completion => \&_complete_filename_or_id,
        },
        detail => {
            schema => 'bool',
            cmdline_aliases => {l=>{}},
        },
    },
};
sub list_files {
    require Regexp::Wildcards;
    require String::Wildcard::Bash;

    my %args = @_;
    my $qq = $args{queries} // [];

    my $parse_res = _parse_mtp_files_output()
        or return $err_no_mtp_files_out;
    my ($files_by_id, $files_by_name) = @$parse_res;

    # convert wildcards to regexes
    $qq = [@$qq];
    for (@$qq) {
        next unless String::Wildcard::Bash::contains_wildcard($_);
        my $re = Regexp::Wildcards->new(type=>'unix')->convert($_);
        $re = qr/\A($re)\z/;
        $_ = $re;
    }

    my @res;
    my %resmeta;

    if ($args{detail}) {
        $resmeta{'table.fields'} = [qw/name id pid size/];
    }

    # XXX report error on non-matching query
    my %seen_ids;
    for my $name (sort keys %$files_by_name) {
        my $ids;
        if (@$qq) {
            for my $q (@$qq) {
                if (ref($q) eq 'Regexp') {
                    if ($name =~ $q) { $ids = $files_by_name->{$name}; last }
                } elsif ($q =~ /\A\d+\z/) {
                    if ($files_by_id->{$q} && !$seen_ids{$q}) {
                        $ids = [$q];
                    }
                } else {
                    if ($name eq $q) { $ids = $files_by_name->{$name}; last }
                }
            }
        } else {
            $ids = $files_by_name->{$name};
        }
        next unless $ids;
        for my $id (@$ids) {
            next if $seen_ids{$id}++;
            my $rec = $files_by_id->{$id};
            if ($args{detail}) {
                push @res, $rec;
            } else {
                push @res, $rec->{name};
            }
        }
    }

    [200, "OK", \@res, \%resmeta];
}

$SPEC{get_files} = {
    v => 1.1,
    summary => 'Get multiple files from MTP (wrapper for mtp-getfile)',
    description => <<'_',

This routine is a thin wrapper for `mtp-file` command from `mtp-tools`.

To use this routine, you must already run `mtp-files` and save its output in
`mtp-files.out` file, e.g.:

    % mtp-files > mtp-files.out

This file is used for tab completion as well as getting filename/ID when only
one is specified. This makes using `mtp-file` less painful.

_
    args => {
        files => {
            summary => 'Filenames/IDs/wildcards',
            'summary.alt.plurality.singular' => 'Filename/ID/wildcard',
            'x.name.is_plural' => 1,
            schema => ['array*', of=>'str*', min_len=>1],
            req => 1,
            pos => 0,
            greedy => 1,
            element_completion => \&_complete_filename_or_id,
        },
        overwrite => {
            schema => 'bool',
            cmdline_aliases => {O=>{}},
        },
    },
    deps => {
        prog => 'mtp-getfile',
    },
};
sub get_files {
    require IPC::System::Options;

    my %args = @_;

    my $res = list_files(queries=>$args{files}, detail=>1);
    return $res unless $res->[0] == 200;

    return [412, "No matching files to get"] unless @{$res->[2]};

    my $num_files = @{ $res->[2] };
    for my $i (1..$num_files) {
        my $file = $res->[2][$i-1];
        $log->infof("[%d/%d] Getting file '%s' ...",
                    $i, $num_files, $file->{name});
        if ((-f $file->{name}) && !$args{overwrite}) {
            $log->warnf("Skipped file '%s' (%d) (already exists)",
                        $file->{name}, $file->{id});
            next;
        }
        IPC::System::Options::system(
            {log=>1, shell=>0},
            "mtp-getfile",
            $file->{id},
            $file->{name},
        );
    }

    [200, "OK"];
}

1;
#ABSTRACT:

=head1 SYNOPSIS

This distribution includes the following CLI utilities:

#INSERT_EXECS_LIST

Currently these utilities are just some wrappers/helpers for the C<mtp-*> CLI
utilities distributed in C<mtp-tools>.


=head1 SEE ALSO

mtp-tools from libmtp, L<http://libmtp.sourceforge.net>
