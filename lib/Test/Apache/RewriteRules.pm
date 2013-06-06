package Test::Apache::RewriteRules;
use strict;
use warnings;
our $VERSION = '1.2';
use File::Temp qw(tempfile tempdir);
use Path::Class;
use Test::Apache::RewriteRules::Net::TCP::FindPort;
use LWP::UserAgent;
use HTTP::Request;
use Test::More;
use Test::Differences;
use Time::HiRes qw(usleep);

our $DEBUG ||= $ENV{TEST_APACHE_DEBUG};

my $data_d = file(__FILE__)->dir->subdir('RewriteRules')->absolute->cleanup;
{
    my $dn = $data_d->stringify;
    1 while $dn =~ s[(^|/)(?!\.\./)[^/]+/\.\.(?=$|/)][$1]g;
    $data_d = dir($dn);
}
my $backend_d = $data_d;

our $HttpdPath = '/usr/sbin/httpd';
our $FoundHTTPDPath;
our $FoundAPXSPath;

sub search_httpd () {
    return if $FoundHTTPDPath and -x $FoundHTTPDPath;
    for (
        $ENV{TEST_APACHE_HTTPD},
        $HttpdPath eq '/usr/sbin/httpd' ? undef : $HttpdPath,
        'local/apache/httpd-2.4/bin/httpd',
        'local/apache/httpd-2.2/bin/httpd',
        'local/apache/httpd-2.0/bin/httpd',
        '/usr/sbin/apache2',
        $HttpdPath eq '/usr/sbin/httpd' ? $HttpdPath : undef,
        '/usr/sbin/httpd',
        '/usr/local/sbin/httpd',
        '/usr/local/apache/bin/httpd',
    ) {
        next unless defined $_;
        if (-x $_) {
            $FoundHTTPDPath = $_;
            note "Found Apache httpd: $FoundHTTPDPath";
            last;
        }
    }

    my $apxs_expected = $FoundHTTPDPath;
    $apxs_expected =~ s{/(?:httpd|apache2)$}{/apxs};
    for (
        $ENV{TEST_APACHE_APXS},
        $apxs_expected,
    ) {
        next unless defined $_;
        if (-x $_) {
            $FoundAPXSPath = $_;
            last;
        }
    }
}

sub available {
    search_httpd;
    return $FoundHTTPDPath && -x $FoundHTTPDPath;
}

sub new {
    my $class = shift;
    return bless {
        backends => [],
    }, $class;
}

sub add_backend {
    my ($self, %args) = @_;
    push @{$self->{backends}}, \%args;
}

sub get_next_port {
    my $self = shift;
    return Test::Apache::RewriteRules::Net::TCP::FindPort->find_listenable_port;
}

sub proxy_port {
    my $self = shift;
    return $self->{proxy_port} ||= $self->get_next_port;
}

sub proxy_host {
    my $self = shift;
    return 'localhost:' . $self->proxy_port;
}

sub proxy_http_url {
    my $self = shift;
    my $path = shift || q</>;
    $path =~ s[^//[^/]*/][/];
    return q<http://> . $self->proxy_host . $path;
}

sub backend_port {
    my ($self, $backend_name) = @_;
    for (@{$self->{backends}}) {
        return $_->{port} ||= $self->get_next_port
            if $_->{name} eq $backend_name;
    }
    die "Can't find backend |$backend_name|";
}

sub backend_host {
    my ($self, $backend_name) = @_;
    return 'localhost:' . $self->backend_port($backend_name);
}

sub get_backend_name_by_port {
    my ($self, $port) = @_;
    for (@{$self->{backends}}) {
        if ($_->{port} and $_->{port} == $port) {
            return $_->{name};
        }
    }
    return undef;
}

sub rewrite_conf_f {
    my $self = shift;
    if (@_) {
        $self->{rewrite_conf_f} = shift->absolute;
        return unless defined wantarray;
    }
    return $self->{rewrite_conf_f};
}

our $CopyDepth = 0;

sub copy_conf_as_f {
    my ($self, $orig_f, $patterns, %args) = @_;
    my $include = $args{rewrite_include};

    local $CopyDepth = $CopyDepth + 1;
    
    $patterns ||= [];
    $patterns = [@$patterns];
    my $conf = $orig_f->slurp;
    if ($include) {
        while ($conf =~ /Include\s+"?([^"\x0D\x0A]+)"?/g) {
            my $conf_file_name = $1;
            my $source_file_name = $include->($conf_file_name);
            if (exists $self->{copied_conf}->{$source_file_name}) {
                if ($self->{copied_conf}->{$source_file_name}) {
                    my $replaced = 'Include ' . $self->{copied_conf}->{$source_file_name};
                    push @$patterns,
                        qr{Include\s+"?\Q$conf_file_name\E"?} => $replaced;
                    warn '  ' x $CopyDepth, "$conf_file_name => $source_file_name => $replaced\n" if $DEBUG;
                } else {
                    warn '  ' x $CopyDepth, "$conf_file_name => $source_file_name => $source_file_name\n" if $DEBUG;
                }
            } else {
                $self->{copied_conf}->{$source_file_name} = undef;
                my $f = $self->copy_conf_as_f(file($source_file_name), $args{inherit_patterns} ? $patterns : [], %args);
                $self->{copied_conf}->{$source_file_name} = $f;
                my $replaced = 'Include ' . $f;
                push @$patterns,
                    qr{Include\s+"?\Q$conf_file_name\E"?} => $replaced;
                warn '  ' x $CopyDepth, "$conf_file_name => $source_file_name => $replaced\n" if $DEBUG;
            }
        }
    }

    while (@$patterns) {
        my $regexp = shift @$patterns;
        $regexp = ref $regexp eq 'Regexp' ? $regexp : qr/\Q$regexp\E/;
        my $new = shift @$patterns;
        my $v = ref $new eq 'CODE' ? $new : sub { $new };
        $conf =~ s/$regexp/$v->()/ge;
    }
    
    my $new_name = $orig_f->basename;
    $new_name =~ s/\.[^.]*//g;
    $new_name .= 'XX'.'XX'.'XX';
    (undef, $new_name) = tempfile($new_name, DIR => $self->server_root_dir_name, SUFFIX => '.conf', CLEANUP => !$DEBUG);

    my $new_f = file($new_name);
    my $new_file = $new_f->openw;
    print $new_file $conf;
    close $new_file;
    
    return $new_f;
}

sub server_root_dir_name {
    my $self = shift;
    return $self->{server_root_dir_name} ||= tempdir('TEST-APACHE-XX'.'XX'.'XX', TMPDIR => 1, CLEANUP => !$DEBUG);
}

sub server_root_d {
    my $self = shift;
    return $self->{server_root_d} ||= dir($self->server_root_dir_name);
}

sub proxy_document_root_d {
    return $backend_d->absolute->cleanup;
}

sub prepare_server_dirs {
    my $self = shift;
    $self->server_root_d->subdir('logs')->mkpath;
}

sub pid_f {
    my $self = shift;
    return $self->{pid_f} ||= $self->server_root_d->file('apache.pid');
}

sub builtin_modules {
    my $self = shift;
    return $self->{builtin_modules} if $self->{builtin_modules};
    my $result;
    $self->run_httpd(['-l'], stdout => \$result) or
        return $self->{builtin_modules} = {};
    return $self->{builtin_modules} = {map { s/^\s+//; s/\s+$//; $_ => 1 } grep { /^ / } split /\n/, $result};
}

sub dso_path {
    search_httpd;
    if ($FoundAPXSPath) {
        return $_[0]->{dso_path} ||= do {
            my $path = `$FoundAPXSPath -q LIBEXECDIR`;
            chomp $path;
            $path;
        };
    } else {
        return 'modules';
    }
}

sub conf_f {
    my $self = shift;
    return $self->{conf_f} ||= $self->server_root_d->file('apache.conf');
}

sub conf_file_name {
    my $self = shift;
    return $self->conf_f->stringify;
}

sub generate_conf {
    my $self = shift;
    
    my $server_root_dir_name = $self->server_root_dir_name;
    $self->prepare_server_dirs;

    my $pid_f = $self->pid_f;
    my $proxy_document_root_d = $self->proxy_document_root_d;
    my $backend_d = $backend_d;
    my $rewrite_conf_f = $self->rewrite_conf_f or die;

    my $proxy_port = $self->proxy_port;

    my $backend_setenvs = '';
    my $backend_vhosts = '';
    for my $backend (@{$self->{backends}}) {
        my $port = $self->backend_port($backend->{name});
        $backend_setenvs .= 'SetEnvIf Request_URI .* ' . $backend->{name} . '=localhost:' . $port . "\n";
        $backend_vhosts .= qq[
Listen $port
<VirtualHost *:$port>
  ServerName $backend->{name}.test:$port
  DocumentRoot $backend_d/
  AddHandler cgi-script .cgi
  <Location $backend_d/>
    Options +ExecCGI
  </Location>
  RewriteEngine on
  RewriteRule /(.*) /url.cgi/\$1 [L]
</VirtualHost>
];
    }

    my $modules = $self->builtin_modules;

    my $mime_types_f = $self->server_root_d->file('mime.types');
    print { $mime_types_f->openw } q{
text/plain txt
text/html html
text/css css
text/javascript js
image/gif gif
image/png png
image/jpeg jpeg jpg
image/vnd.microsoft.icon ico
    };

    my $conf_file_name = $self->conf_f->stringify;
    open my $conf_f, '>', $conf_file_name or die "$0: $conf_file_name: $!";

    my $dso_path = $self->dso_path;
    for (qw(
        log_config setenvif alias rewrite authn_file authz_host auth_basic
        mime ssl proxy proxy_http cgi actions
    )) {
        printf $conf_f "LoadModule %s_module $dso_path/mod_%s.so\n", $_, $_
            unless $modules->{"mod_$_.c"};
    }
    
    print $conf_f qq[
LogLevel debug

ServerName test
ServerRoot $server_root_dir_name
PidFile $pid_f
LockFile $server_root_dir_name/accept.lock
CustomLog logs/access_log "%v\t%h %l %u %t %r %>s %b"
TypesConfig $mime_types_f

Listen $proxy_port
<VirtualHost *:$proxy_port>
  ServerName proxy.test:$proxy_port
  DocumentRoot $proxy_document_root_d/
  $backend_setenvs

  RewriteRule ^/url\\.cgi/ - [L]
  Alias /url.cgi $proxy_document_root_d/url.cgi
  RewriteLog logs/rewrite_log
  RewriteLogLevel 9

  Include "$rewrite_conf_f"

  Action default-proxy-handler /url.cgi virtual
  SetHandler default-proxy-handler

  <Location /url.cgi>
    SetHandler cgi-script
  </Location>
</VirtualHost>

$backend_vhosts
];

    close $conf_f;
    $self->{conf_generated} = 1;
}

sub conf_generated {
    my $self = shift;
    return $self->{conf_generated};
}

sub run_httpd {
    my ($self, $args, %opt) = @_;
    search_httpd;
    unless (-x $FoundHTTPDPath) {
        warn "$0: Can't find httpd\n";
        return 0;
    }
    if ($opt{stdout}) {
        if (open my $file, '-|', $FoundHTTPDPath, @$args) {
            local $/ = undef;
            ${$opt{stdout}} = <$file>;
        }
    } else {
        system $FoundHTTPDPath, @$args;
    }
    if ($? == -1) {
        warn "$0: $FoundHTTPDPath: $!\n";
        return 0;
    } elsif ($? & 127) {
        warn "$0: $FoundHTTPDPath: " . ($? & 127) . "\n";
        return 0;
    } elsif ($? >> 8 != 0) {
        warn "$0: $FoundHTTPDPath: Exit with status " . ($? >> 8) . "\n";
        return 0;
    } else {
        return 1;
    }
}

sub start_apache {
    my $self = shift;
    $self->generate_conf unless $self->conf_generated;
    my $conf = $self->conf_file_name or die;
    warn "Starting apache with $conf...\n" if $DEBUG;
    $self->run_httpd(['-f' => $conf, '-k' => 'start'])
        or BAIL_OUT "Can't start apache";
    $self->wait_for_starting_apache;
}

sub wait_for_starting_apache {
    my $self = shift;
    my $pid_f = $self->pid_f;
    warn sprintf "Waiting for starting apache process (%s)...\n",
        $self->server_root_dir_name;
    my $i = 0;
    while (not -f $pid_f) {
        usleep 10_000;
        if ($i++ >= 100_00) {
            die "$0: $FoundHTTPDPath: Apache does not start in 100 seconds";
        }
    }
}

sub stop_apache {
    my $self = shift;
    my $conf = $self->conf_file_name or die;
    for (1..5) {
        $self->run_httpd(['-f' => $conf, '-k' => 'stop']) or next;
        return if $self->wait_for_stopping_apache;
    }
    die "$0: $FoundHTTPDPath: Cannot stop apache\n";
}

sub wait_for_stopping_apache {
    my $self = shift;
    my $pid_f = $self->pid_f;
    warn sprintf "Waiting for stopping apache process (%s)...\n",
        $self->server_root_dir_name;
    my $i = 0;
    while (-f $pid_f) {
        usleep 10_000;
        if ($i++ >= 10_00) {
            warn "$0: $FoundHTTPDPath: Apache does not end in 10 seconds\n";
            return 0;
        }
    }
    return 1;
}

sub DESTROY {
    my $self = shift;
    if (-f $self->pid_f) {
        $self->stop_apache;
    }
}


sub get_rewrite_result {
    my ($self, %args) = @_;

    my $url = $self->proxy_http_url($args{orig_path});
    my $method = $Test::Apache::RewriteRules::ClientEnvs::RequestMethod || 'GET';

    my $req = HTTP::Request->new($method => $url);
    my $ua = LWP::UserAgent->new(max_redirect => 0, agent => '');

    my $UA = $Test::Apache::RewriteRules::ClientEnvs::UserAgent;
    if (defined $UA) {
        $UA =~ s/%%SBSerialNumber%%//g;
        $req->header('User-Agent' => $UA);
    }

    if ($args{orig_path} =~ m[^//([^/]*)/]) {
        $req->header(Host => $1);
    }

    my $cookies = $Test::Apache::RewriteRules::ClientEnvs::Cookies || [];
    if (@$cookies) {
        $cookies = [@$cookies];
        my @c;
        while (@$cookies) {
            my $n = shift @$cookies;
            my $v = shift @$cookies;
            push @c, $n . '=' . $v;
        }
        $req->header(Cookie => join '; ', @c);
    }

    my $header = $Test::Apache::RewriteRules::ClientEnvs::HttpHeader || [];
    if (@$header) {
        $header = [@$header];
        my @c;
        while (@$header) {
            my $n = shift @$header;
            my $v = shift @$header;
            $req->header($n => $v);
        }
    }

    my $res = $ua->request($req);

    my $code = $res->code;

    my $result = $code >= 300 ? '' : join "\n", (split /\n/, $res->content)[0, $args{use_path_translated} ? 2 : 1];
    $result =~ s/^(localhost:(\d+))/$1 . q[ (].($self->get_backend_name_by_port($2) || '').q[)]/e;
    $result = $code . ' ' . ($res->header('Location') || '') . "\n" . $result;
    return $result;
}

sub is_host_path {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    
    my ($self, $orig_path, $backend_name, $path, $name) = @_;

    my $result = $self->get_rewrite_result(orig_path => $orig_path, use_path_translated => ($backend_name eq ''));

    my $host = $backend_name
        ? $self->backend_host($backend_name)
        : $self->proxy_host;
    $host .= " ($backend_name)";

    eq_or_diff $result, "200 \n" . $host . "\n" . $path, $name;
}

sub is_redirect {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    
    my ($self, $orig_path, $redirect_url, $name, %args) = @_;

    my $result = $self->get_rewrite_result(orig_path => $orig_path);

    my $code = $args{code} || 302;
    eq_or_diff $result, "$code $redirect_url\n", $name;
}

sub is_status_code {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    
    my ($self, $orig_path => $code, $name) = @_;

    my $result = $self->get_rewrite_result(orig_path => $orig_path);
    $result = $1 if $result =~ /^([0-9]+)/;

    eq_or_diff $result, $code || 200, $name;
}

1;
