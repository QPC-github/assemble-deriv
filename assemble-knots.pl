#!/usr/bin/perl
# kate: space-indent off;
use strict;
use warnings;

use IPC::Open2;

# TODO: check that merges don't pull in extraneous junk [from master]
# TODO: cherry-picked commits in rebasing branch
# TODO: compare result of each merge

my $expect_to_rebase = 1;

my $specfn = shift;

my $hexd = qr/[\da-f]/i;

sub makegitcmd {
	("git", "--no-pager", @_)
}

sub gitmayfail {
	my @cmd = makegitcmd(@_);
	print "@cmd\n";
	system @cmd
}

sub git {
	my $ec = gitmayfail(@_);
	die "git @_ failed" if $ec;
}

sub gitcapture {
	my @cmd = makegitcmd(@_);
	print "@cmd\n";
	open(my $outio, "-|", @cmd);
	my $out;
	{
		local $/;
		$out = <$outio>;
	}
	close $outio;
	die "git @_ failed" if $?;
	chomp $out;
	$out
}

sub patchid {
	my @cmd = makegitcmd("patch-id", "--stable");
	my ($outio, $inio);
	open2($outio, $inio, @cmd) or die;
	print $inio shift;
	close $inio;
	my $out;
	{
		local $/;
		$out = <$outio>;
	}
	close $outio;
	chomp $out;
	$out =~ s/\s.*$//;
	$out
}

sub gitresethard_formerge {
	# git reset --hard, but without clearing merge info
	my $gitstatus = gitcapture("status", "-uno", "--porcelain", "-z");
	for my $gitstatusline (split /\0/, $gitstatus) {
		my ($status, $path) = ($gitstatusline =~ /^(..) (.*)$/);
		$status =~ s/\s+//;
		if ($status =~ /^([MDU])\g1?$/) {
			git("checkout", "HEAD", $path);
		} elsif ($status eq 'A') {
			git("rm", "-f", $path);
		} elsif ($status eq 'R') {
			my @paths = split /\s/, $path;
			die "Too many paths or space in renamed path: $gitstatusline" if @paths != 2;
			git("checkout", "HEAD", $paths[1]);
			git("rm", "-f", $paths[0]);
		} else {
			die "Unknown status: $gitstatusline"
		}
	}
}

sub wc_l {
	1 + ($_[0] =~ tr/\n//)
}

sub userfix {
	print("Backgrounding so you can fix this...\n");
	kill('STOP', $$);
	
	# SIGCONT resumes here
}

sub mymerger {
	my ($merge_from) = @_;
	my $merge_ec = gitmayfail("merge", "--no-commit", $merge_from);
	my $diff = gitcapture("diff", "HEAD");
	if (not $merge_ec) {
		# Check if it was a no-op
		my $difflines = wc_l($diff);
		if (!$difflines) {
			return "tree";
		}
		return "clean";
	}
	
	my $conflict_id = patchid($diff);
	
	my $resbase = "assemble-knots-resolutions/$conflict_id";
	if (-e "$resbase.diff") {
		gitresethard_formerge();
		git("apply", "--index", "--whitespace=nowarn", "$resbase.diff");
		print("Conflict ID: $conflict_id AUTOPATCHING\n");
		return "clean";
	}
	
	if (-e "$resbase.res") {
		open(my $resfh, "<", "$resbase.res");
		my $res = <$resfh>;
		close $resfh;
		print("Conflict ID: $conflict_id AUTORESOLVING with $res\n");
		return $res;
	}
	
	gitmayfail("-p", "diff", "--color=always", "HEAD");
	print("Conflict ID: $conflict_id\n");
	
	''
}

open(my $spec, '<', $specfn);
while (<$spec>) {
	s/\s*#.*//;  # remove comments
	if (m/^\s*$/) {
		# blank line, skip
	} elsif (m/^checkout (.*)$/) {
		my $branchhead = gitcapture("rev-parse", $1);
		git "checkout", $branchhead;
	} elsif (m/^\@(.*)$/) {
		#git "checkout", "-b", "NEW_$1";
	} elsif (my ($prnum, $rem) = (m/^\t(\d+|\-|n\/a)\s+(.*)$/)) {
		$rem =~ m/(\S+)?(?:\s+($hexd{7,}\b))?$/ or die;
		my ($branchname, $lastapply) = ($1, $2);
		if (not defined $branchname) {
			die "No branch name?" if not $prnum;
			$branchname = "origin-pull/$prnum/head";
		}
		if (my ($remote, $remote_ref) = ($branchname =~ m[^([^/]+)\/(.*)$])) {
			git "fetch", $remote;
		}
		my $branchparent = $branchname;
		my $mainmerge = $branchname;
		
		my ($merge_lastapply, $merge_more);
		if (defined $lastapply) {
			$merge_lastapply = (wc_l(gitcapture("log", "--pretty=oneline", "--first-parent", "..$lastapply")) == 1);
			die "Skipping a parent in rebase! Aborting" if $expect_to_rebase and not $merge_lastapply;
			if ($merge_lastapply) {
				# Regardless of whether the main branch has added commits or not, we want to start by merging the previous merge
				$mainmerge = $lastapply;
				$merge_more = wc_l(gitcapture("log", "--pretty=oneline", "$lastapply..$branchname")) > 0;
			}
		}
		
		my $commitmsg = "Merge " . (($prnum > 0) ? "$prnum via " : "") . "$branchname";
		my $is_tree_merge;
		{
			my $res = mymerger($mainmerge);
			if ($res eq 'tree') {
				$is_tree_merge = 1;
			} elsif ($res eq 'clean') {
				# good, nothing to do here
			} else {
				while ($res !~ /^[123]$/) {
					print "Conflict found: 1) Fix, 2) Abort, or 3) Tree-merge\n";
					$res = <>;
				}
				if ($res == 1) {
					userfix;
				} elsif ($res == 2) {
					die "Aborted\n";
				} elsif ($res == 3) {
					gitresethard_formerge();
					$is_tree_merge = 1;
				}
			}
		}
		if ($is_tree_merge) {
			if (not $merge_lastapply) {
				# Why bother with a tree-merge at all?
				die "$prnum $branchname is a tree-merge, but not doing rebasing...";
			}
			$commitmsg = "Tree-$commitmsg";
		}
		git("commit", "-am", $commitmsg);
		if ($merge_more) {
			my $res = mymerger($branchname);
			if ($res eq 'tree') {
				# If it doesn't change anything, just skip it entirely
				undef $merge_more;
			} elsif ($res eq 'clean') {
				# good, nothing to do here
			} else {
				while ($res !~ /^[123]$/) {
					print "Conflict found: 1) Fix, 2) Abort, or 3) Ignore updates\n";
					$res = <>;
				}
				if ($res == 1) {
					userfix;
				} elsif ($res == 2) {
					die "Aborted\n";
				} elsif ($res == 3) {
					undef $merge_more;
				}
			}
			if ($merge_more) {
				# TODO: Something to prevent failure due to in-progress merge?
				git("commit", "-a", "--amend", "--no-edit");
				undef $is_tree_merge;
			} else {
				git("reset", "--hard");
				$branchparent = $lastapply . "^2";
			}
		}
		if ($merge_lastapply and not $is_tree_merge) {
			# Rewrite commit to parent directly
			my $tree = gitcapture("write-tree");
			my $chash = gitcapture("commit-tree", $tree, "-m", $commitmsg, "-p", "HEAD^", "-p", $branchparent, "-p", $lastapply);
			git("checkout", "-q", $chash);
		}
	} else {
		die "Unrecognised line: $_"
	}
}
