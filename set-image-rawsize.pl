#!/usr/local/bin/perl

=head1 set-image-rawsize.pl

Internal script to set the un-compressed size of Xen filesystem images

=cut

package server_manager;
$main::no_acl_check++;
$ENV{'WEBMIN_CONFIG'} ||= "/etc/webmin";
$ENV{'WEBMIN_VAR'} ||= "/var/webmin";
if ($0 =~ /^(.*\/)[^\/]+$/) {
	chdir($1);
	}
chop($pwd = `pwd`);
$0 = "$pwd/set-image-rawsize.pl";
require './server-manager-lib.pl';
$< == 0 || die "$0 must be run as root";

@images = grep { !$_->{'rawsize'} } &list_server_images("xen");
IMAGE: foreach $i (@images) {
	print "Doing $i->{'id'}\n";
	$i->{'rawsize'} = 0;
	foreach $f (split(/\s+/, $i->{'files'})) {
		$out = &backquote_command(
			$f =~ /\.gz/ ? 
			  "(gunzip -c $server_images_dir/$f | wc -c) 2>&1" :
			  "wc -c $server_images_dir/$f 2>&1");
		if ($?) {
			print STDERR "Un-compression of $f failed : $out\n";
			next IMAGE;
			}
		$i->{'rawsize'} += int($out);
		}
	&save_server_image($i);
	print "Size is $i->{'rawsize'}\n";
	}

