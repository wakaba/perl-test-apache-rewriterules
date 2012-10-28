all:

## ------ Setup ------

GIT = git
WGET = wget

local/bin/pmbp.pl:
	mkdir -p local/bin
	$(WGET) -O $@ https://raw.github.com/wakaba/perl-setupenv/master/bin/pmbp.pl

pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl --update-pmbp-pl

pmbp-update: pmbp-upgrade
	perl local/bin/pmbp.pl --update

pmbp-install: pmbp-update
	perl local/bin/pmbp.pl --install \
	    --install-apache 2.2 \
	    --create-perl-command-shortcut perl \
	    --create-perl-command-shortcut prove

deps: git-submodules pmbp-install

git-submodules:
	$(GIT) submodule update --init

## ------ Tests ------

PROVE = ./prove

test: test-deps test-main

test-deps: deps

test-main:
	TEST_APACHE_HTTPD=local/apache/httpd-2.2/bin/httpd \
	$(PROVE) t/test/*.t
