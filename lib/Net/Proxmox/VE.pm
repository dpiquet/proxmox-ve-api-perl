#!/bin/false

package Net::Proxmox::VE;

use Carp qw( croak );
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Request::Common qw(GET POST DELETE);
use JSON qw(decode_json);
#use namespace::sweep; # like autoclean, but with no Mooses

sub new {

    my $c = shift;
    my @p = @_;
    my $class = ref($c) || $c;

    my %params;

    if (scalar @p == 1) {

        croak 'new() requires a hash for params'
            unless ref $p[0] eq 'HASH';

        %params = %{$p[0]};

    } else {
        %params = @p 
            or croak 'new() requires a hash for params';
    }

    croak 'host param is required'     unless $params{'host'};
    croak 'password param is required' unless $params{'password'};

    $params{port}     ||= 8006;
    $params{username} ||= 'root';
    $params{realm}    ||= 'pam';
    $params{debug}    ||= undef;

    my $self->{params}          = \%params;
    $self->{'ticket'}           = undef;
    $self->{'ticket_timestamp'} = undef;
    $self->{'ticket_life'}      = 7200; # 2 Hours

    bless $self, $class;
    return $self

}

sub url_prefix {
    my $self = shift || return;

    # Prepare login request
    my $url_prefix = 'https://'
        . $self->{params}->{host}
        . ':'
        . $self->{params}->{port};

    return $url_prefix
}

sub login {
    my $self = shift || return;
        
    # Prepare login request
    my $url = $self->url_prefix . '/api2/json/access/ticket';
    
    my $ua = LWP::UserAgent->new();
    $ua->ssl_opts(verify_hostname => undef); # Add only if test environment here

    # Perform login request
    my $request_time = time();
    my $response = $ua->post(
        $url,
        {
            'username' => $self->{params}->{username} . '@' . $self->{params}->{realm},
            'password' => $self->{params}->{password},
        },
    );

    if ($response->is_success) {
        my $content = $response->decoded_content;
            my $login_ticket_data = decode_json $response->decoded_content;
            $self->{ticket} = $login_ticket_data->{data};
            # We use request time as the time to get the json ticket is undetermined,
            # id rather have a ticket a few seconds shorter than have a ticket that incorrectly
            # says its valid for a couple more
            $self->{ticket_timestamp} = $request_time;
            print "DEBUG: login successful\n"
                if $self->{params}->{debug};
            return 1;
    }

    print "DEBUG: login not successful\n"
        if $self->{params}->{debug};

    return
    
}

sub check_login_ticket {
    my $self = shift || return;

    if (
        $self->{ticket}
        && ref $self->{ticket} eq 'HASH'
        && $self->{ticket}
        && $self->{ticket}->{ticket}
        && $self->{ticket}->{CSRFPreventionToken}
        && $self->{ticket}->{username} eq $self->{params}->{username} . '@' . $self->{params}->{realm}
        && $self->{ticket_timestamp}
        && $self->{ticket_timestamp} < (time() + $self->{ticket_life})
    ) {
        return 1
    }
    else {
        $self->{ticket} = undef;
        $self->{ticket_timestamp} = undef;
    }

    return
}


sub action {
    my $self = shift || return;
    my %params = @_;
    
    unless (%params) {
        croak 'new requires a hash for params';
    }
    croak 'path param is required' unless $params{path};
    
    $params{method}    ||= 'GET';
    $params{post_data} ||= {};

    # Check its a valid method
    unless (
        $params{method}    eq 'GET'
        || $params{method} eq 'PUT'
        || $params{method} eq 'POST'
        || $params{method} eq 'DELETE'
    ){
        croak "invalid http method specified: $params{method}";
    }

    # Strip prefixed / to path if present
    $params{path} =~ s/^\///;
        
    unless ($self->check_login_ticket) {
        print "DEBUG: invalid login ticket\n"
            if $self->{params}->{debug};
        return unless $self->login();
    }

    my $url = $self->url_prefix . '/api2/json/' . $params{path};

    # Setup the useragent
    my $ua = LWP::UserAgent->new();
    $ua->ssl_opts(verify_hostname => undef); # Add only if test environment here

    # Setup the request object
    my $request = HTTP::Request->new();
    $request->uri($url);
    $request->header('Cookie' => 'PVEAuthCookie=' . $self->{ticket}->{ticket});

    my $response;

    # all methods other than get require the prevention token
    # (ie anything that makes modification)
    unless ($params{method} eq 'GET') {
        $request->header('CSRFPreventionToken' => $self->{ticket}->{CSRFPreventionToken});
    }

    # Not sure why but the php api for proxmox ve uses PUT instead of post for
    # most things, the api doc only lists GET|POST|DELETE and the api returns 'PUT' as
    # an unrecognised method
    # so we'll just force POST from PUT
    if (
        $params{method}    eq 'PUT'
        || $params{method} eq 'POST'
    ) {
        $request->method('POST');
        my $content = join '&', map { $_ . '=' . $params{post_data}->{$_} } sort keys %{$params{post_data}};
        $request->content($content);
        $response = $ua->request($request);
    }
    elsif (
        $params{method}    eq 'GET'
        || $params{method} eq 'DELETE'
    ) {
        $request->method($params{method});
        $response = $ua->request($request);
    }

    if ($response->is_success) {
        print "DEBUG: successful request: " . $request->as_string . "\n"
            if $self->{params}->{debug};

        my $content = $response->decoded_content;
        my $data = decode_json $response->decoded_content;
        # DELETE operations return no data
        # otherwise if we have a data key but its empty, treat it as a failure
        if ($params{method} eq 'DELETE') {
            return 1;
        }
        elsif (
                ref($data) eq 'HASH'
                && exists $data->{data}
        ){
            return $data->{data} || 1;
        }
        else {
            return
        }
    }
    else {
        print "WARNING: request failed: " . $request->as_string . "\n";
        print "WARNING: response status: " . $response->status_line . "\n";
        return
    }
}

sub reload_node_list {
    my $self = shift || return;

    my $node_list = $self->action(path => '/nodes', method => 'GET');
    if (@{$node_list} > 0) {
        $self->{node_list} = $node_list;
        return 1;
    }
   
    print "ERROR: empty list of nodes in this cluster.\n";

    return
}

sub get_node_list {
    my $self = shift || return;

    if ($self->{node_list}) {
        return $self->{node_list};
    }
    elsif ($self->reload_node_list) {
        return $self->{node_list};
    }

    return
}

sub get {
    my $self = shift || return;
    my $path = shift || return;
    
    if ($self->get_node_list) {
        return $self->action(path => $path, method => 'GET');
    }
    return
}

sub delete {
    my $self = shift || return;
    my $path = shift || return;
    
    if ($self->get_node_list) {
        return $self->action(path => $path, method => 'DELETE');
    }
    return
}

sub put {
    my $self = shift;
    return $self->post(@_);
}

sub post {
    my $self      = shift || return;    
    my $path      = shift || return;
    my $post_data = shift || return;

    if ($self->get_node_list) {
        return $self->action(path => $path, method => 'POST', post_data => $post_data);
    }
    return;
}


1
