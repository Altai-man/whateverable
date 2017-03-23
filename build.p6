#!/usr/bin/env perl6
# Copyright © 2016
#     Aleks-Daniel Jakimenko-Aleksejev <alex.jakimenko@gmail.com>
#     Daniel Green <ddgreen@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# This script will build rakudo for all commits that it can find

use File::Temp;
use File::Directory::Tree;

constant PARALLEL-COUNT    = 1;
constant COMMIT-RANGE      = ‘2015.07^..HEAD’;
constant TAGS-SINCE        = ‘2014-01-01’;

constant WORKING-DIRECTORY = ‘.’; # TODO not supported yet

constant RAKUDO-ORIGIN     = ‘https://github.com/rakudo/rakudo.git’;
constant RAKUDO-LATEST     = ‘/tmp/whateverable/rakudo-repo’;
constant RAKUDO-CURRENT    = “{WORKING-DIRECTORY}/rakudo”.IO.absolute;

constant ARCHIVES-LOCATION = “{WORKING-DIRECTORY}/builds/rakudo-moar”.IO.absolute;
constant BUILDS-LOCATION   = ‘/tmp/whateverable/rakudo-moar’;
constant BUILD-LOCK        = ‘/tmp/whateverable/build-lock’;

constant GIT-REFERENCE     = WORKING-DIRECTORY.IO.absolute;

mkdir BUILDS-LOCATION;
mkdir ARCHIVES-LOCATION;

# TODO IO::Handle.lock ? run ‘flock’? P5 modules?
exit 0 unless run ‘mkdir’, :err(Nil), ‘--’, BUILD-LOCK; # only one instance running
my $locked = True;
END BUILD-LOCK.IO.rmdir if $locked;

# TODO should we also pull nqp/ and MoarVM/ ?
if RAKUDO-LATEST.IO ~~ :d  {
    my $old-dir = $*CWD;
    LEAVE chdir $old-dir;
    chdir RAKUDO-LATEST;
    run ‘git’, ‘pull’;
} else {
    exit unless run ‘git’, ‘clone’, ‘--’, RAKUDO-ORIGIN, RAKUDO-LATEST;
}

if RAKUDO-CURRENT.IO !~~ :d  {
    run ‘git’, ‘clone’, ‘--’, RAKUDO-LATEST, RAKUDO-CURRENT;
}

my $channel = Channel.new;

my @git-latest = ‘git’, ‘--git-dir’, “{RAKUDO-LATEST}/.git”, ‘--work-tree’, RAKUDO-LATEST;
my @args-tags   = |@git-latest, ‘log’, ‘-z’, ‘--pretty=%H’, ‘--tags’, ‘--no-walk’, ‘--since’, TAGS-SINCE;
my @args-latest = |@git-latest, ‘log’, ‘-z’, ‘--pretty=%H’, COMMIT-RANGE;

#$channel.send: $_ for run(:out, |@args-tags  ).out.split(0.chr, :skip-empty);
# ↑ TODO this ends with Nil or an empty string for some reason? It makes
# this check: ｢last unless $commit｣ exit from the loop, so it never reaches
# actual commits.
$channel.send: $_ for run(:out, |@args-latest).out.split(0.chr, :skip-empty);

await (for ^PARALLEL-COUNT { # TODO rewrite when .race starts working in rakudo
              start loop {
                  my $commit = $channel.poll;
                  last unless $commit;
                  try { process-commit($commit) }
              }
          });

# update rakudo repo so that bots know about latest commits
run ‘git’, ‘--git-dir’, “{RAKUDO-CURRENT}/.git”, ‘--work-tree’, RAKUDO-CURRENT, ‘pull’, ‘--tags’, RAKUDO-LATEST;

sub process-commit($commit) {
    return if “{ARCHIVES-LOCATION}/$commit.zst”.IO ~~ :e; # already exists

    my ($temp-folder,) = tempdir, :!unlink;
    my $build-path   = “{BUILDS-LOCATION}/$commit”.IO.absolute;
    my $log-path     = $build-path;
    my $archive-path = “{ARCHIVES-LOCATION}/$commit.zst”.IO.absolute;

    # ⚡ clone
    run ‘git’, ‘clone’, ‘-q’, ‘--’, RAKUDO-LATEST, $temp-folder;
    # ⚡ checkout to $commit
    my @git-temp = ‘git’, ‘--git-dir’, “$temp-folder/.git”, ‘--work-tree’, $temp-folder;
    run |@git-temp, ‘reset’, ‘-q’, ‘--hard’, $commit;

    # No :merge for log files because RT #125756 RT #128594

    my $config-ok;
    mkdir $build-path;
    {
        # ⚡ configure
        my $old-dir = $*CWD;
        LEAVE chdir $old-dir;
        chdir $temp-folder;
        say “»»»»» $commit: configure”;
        my $configure-log-fh = open :w, “$log-path/configure.log”;
        my $configure-err-fh = open :w, “$log-path/configure.err”;
        $config-ok = run(:out($configure-log-fh), :err($configure-err-fh),
                         ‘perl’, ‘--’, ‘Configure.pl’,
                         ‘--gen-moar’, ‘--gen-nqp’, ‘--backends=moar’, “--prefix=$build-path”,
                         “--git-reference={GIT-REFERENCE}” );
        $configure-log-fh.close;
        $configure-err-fh.close;
        say “»»»»» Cannot configure $commit” unless $config-ok;
    }

    my $make-ok;
    if $config-ok {
        # ⚡ make
        say “»»»»» $commit: make”;
        my $make-log-fh = open :w, “$log-path/make.log”;
        my $make-err-fh = open :w, “$log-path/make.err”;
        $make-ok = run(:out($make-log-fh), :err($make-err-fh),
                       ‘make’, ‘-C’, $temp-folder);
        $make-log-fh.close;
        $make-err-fh.close;
        say “»»»»» Cannot make $commit” unless $make-ok;
    }
    if $make-ok {
        # ⚡ make install
        say “»»»»» $commit: make install”;
        my $install-log-fh = open :w, “$log-path/make-install.log”;
        my $install-err-fh = open :w, “$log-path/make-install.err”;
        my $install-ok = run(:out($install-log-fh), :err($install-err-fh),
                             ‘make’, ‘-C’, $temp-folder, ‘install’);
        $install-log-fh.close;
        $install-err-fh.close;
        say “»»»»» Cannot install $commit” unless $install-ok;
    }

    # ⚡ compress
    # No matter what we got, compress it
    say “»»»»» $commit: compressing”;
    my $proc = run(:out, :bin, ‘tar’, ‘cf’, ‘-’, ‘--absolute-names’, ‘--remove-files’, ‘--’, $build-path);
    run(:in($proc.out), :bin, ‘zstd’, ‘-c’, ‘-19’, ‘-q’, ‘-o’, $archive-path);

    rmtree $temp-folder;
}
