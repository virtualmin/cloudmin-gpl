#!/bin/sh
# Install distribution packages for the standalone Perl helper
# during cloud-init.
set -eu
export DEBIAN_FRONTEND=noninteractive
export INTERACTIVE_MODE=off

if command -v apt-get >/dev/null 2>&1; then
	# Debian splits the HTTP, JSON and TLS modules into separate packages.
	apt-get update
	apt-get -o DPkg::Lock::Timeout=600 install -y -- \
		perl libjson-pp-perl libhttp-tiny-perl liburi-perl \
		libio-socket-ssl-perl libnet-ssleay-perl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
	# Include split core modules on minimal Enterprise Linux images,
	# including EL8.
	dnf install -y -- \
		perl-interpreter perl-Time-HiRes perl-JSON-PP perl-HTTP-Tiny \
		perl-URI \
		perl-IO-Socket-SSL perl-Net-SSLeay ca-certificates
elif command -v zypper >/dev/null 2>&1; then
	# Resolve modules whether SUSE bundles them with Perl or packages
	# them alone.
	zypper --non-interactive refresh
	zypper --non-interactive install -- \
		perl 'perl(JSON::PP)' 'perl(HTTP::Tiny)' \
		'perl(URI)' 'perl(IO::Socket::SSL)' 'perl(Net::SSLeay)' \
		ca-certificates
else
	# Fail cloud-init rather than leave an unusable software
	# service installed.
	echo 'Guest software setup requires a supported package manager' >&2
	exit 1
fi

# Fail initial setup if the installed runtime cannot load the seeded helper.
/usr/bin/perl -c /usr/local/lib/cloudmin/guest-software.pl
