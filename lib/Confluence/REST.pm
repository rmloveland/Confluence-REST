package Confluence::REST;
# ABSTRACT: Thin wrapper around Confluence's REST API
$CONFLUENCE::REST::VERSION = '0.011';
use 5.010;
use utf8;
use strict;
use warnings;

use Carp;
use URI;
use MIME::Base64;
use URI::Escape;
use JSON;
use Data::Util qw/:check/;
use REST::Client;
use Data::Dumper;

our $DEBUG_REQUESTS_P = 0;
our $DEBUG_JSON_P     = 0;
our $DEBUG_ITERATORS  = 0;

sub new {
    my ($class, $URL, $username, $password, $rest_client_config) = @_;

    $URL = URI->new($URL) if is_string($URL);
    is_instance($URL, 'URI')
        or croak __PACKAGE__ . "::new: URL argument must be a string or a URI object.\n";

    # Choose the latest REST API unless already specified
    unless ($URL->path =~ m@/rest/api/(?:\d+|content)/?$@) {
        $URL->path($URL->path . '/rest/api/content');
    }

    # If no password is set we try to lookup the credentials in the .netrc file
    if (! defined $password) {
        eval {require Net::Netrc}
            or croak "Can't require Net::Netrc module. Please, specify the USERNAME and PASSWORD.\n";
        if (my $machine = Net::Netrc->lookup($URL->host, $username)) { # $username may be undef
            $username = $machine->login;
            $password = $machine->password;
        } else {
            croak "No credentials found in the .netrc file.\n";
        }
    }

    is_string($username)
        or croak __PACKAGE__ . "::new: USERNAME argument must be a string.\n";

    is_string($password)
        or croak __PACKAGE__ . "::new: PASSWORD argument must be a string.\n";

    $rest_client_config = {} unless defined $rest_client_config;
    is_hash_ref($rest_client_config)
        or croak __PACKAGE__ . "::new: REST_CLIENT_CONFIG argument must be a hash-ref.\n";

    # remove the REST::Client faux config value 'proxy' if set and use it
    # ourselves.
    my $proxy = delete $rest_client_config->{proxy};

    if ($proxy) {
        is_string($proxy) || is_instance($proxy, 'URI')
            or croak __PACKAGE__ . "::new: 'proxy' rest client attribute must be a string or a URI object.\n";
    }

    my $rest = REST::Client->new($rest_client_config);

    # Set proxy to be used
    if ($proxy) {
        $rest->getUseragent->proxy(['http','https'] => $proxy);
    }

    # Set default base URL
    $rest->setHost($URL);

    # Follow redirects/authentication by default
    $rest->setFollow(1);

    # Since Confluence doesn't send an authentication chalenge, we may
    # simply force the sending of the authentication header.
    $rest->addHeader(Authorization => 'Basic ' . encode_base64("$username:$password"));

    # Configure UserAgent name
    $rest->getUseragent->agent(__PACKAGE__);

    return bless {
        rest => $rest,
        json => JSON->new->utf8->allow_nonref,
    } => $class;
}

sub _error {
    my ($self, $content, $type, $code) = @_;

    $type = 'text/plain' unless $type;
    $code = 500          unless $code;

    my $msg = __PACKAGE__ . " Error[$code";

    if (eval {require HTTP::Status}) {
        if (my $status = HTTP::Status::status_message($code)) {
            $msg .= " - $status";
        }
    }

    $msg .= "]:\n";

    if ($type =~ m:text/plain:i) {
        $msg .= $content;
    } elsif ($type =~ m:application/json:) {
        my $error = $self->{json}->decode($content);
        if (ref $error eq 'HASH') {
            # Confluence errors may be laid out in all sorts of ways. You have to
            # look them up from the scant documentation at
            # https://docs.atlassian.com/confluence/REST/latest/.

            # /issue/bulk tucks the errors one level down, inside the
            # 'elementErrors' hash.
            $error = $error->{elementErrors} if exists $error->{elementErrors};

            # Some methods tuck the errors in the 'errorMessages' array.
            if (my $errorMessages = $error->{errorMessages}) {
                $msg .= "- $_\n" foreach @$errorMessages;
            }

            # And some tuck them in the 'errors' hash.
            if (my $errors = $error->{errors}) {
                $msg .= "- [$_] $errors->{$_}\n" foreach sort keys %$errors;
            }
        } else {
            $msg .= $content;
        }
    } elsif ($type =~ m:text/html:i && eval {require HTML::TreeBuilder}) {
        $msg .= HTML::TreeBuilder->new_from_content($content)->as_text;
    } elsif ($type =~ m:^(text/|application|xml):i) {
        $msg .= "<Content-Type: $type>$content</Content-Type>";
    } else {
        $msg .= "<Content-Type: $type>(binary content not shown)</Content-Type>";
    };
    $msg =~ s/\n*$/\n/s;       # end message with a single newline
    return $msg;
}

sub _content {
    my ($self) = @_;

    my $rest    = $self->{rest};
    my $code    = $rest->responseCode();
    my $type    = $rest->responseHeader('Content-Type');
    my $content = $rest->responseContent();

    $code =~ /^2/
        or croak $self->_error($content, $type, $code);

    return unless $content;

    if (! defined $type) {
        croak $self->_error("Cannot convert response content with no Content-Type specified.");
    } elsif ($type =~ m:^application/json:i) {
        my $decoded = $self->{json}->decode($content);
        print Dumper $decoded if $DEBUG_JSON_P;
        return $decoded;
    } elsif ($type =~ m:^text/plain:i) {
        return $content;
    } else {
        croak $self->_error("I don't understand content with Content-Type '$type'.");
    }
}

sub _build_query {
    my ($self, $query) = @_;

    is_hash_ref($query) or croak $self->_error("The QUERY argument must be a hash-ref.");

    return '?'. join('&', map {$_ . '=' . uri_escape($query->{$_})} keys %$query);
}

sub GET {
    my ($self, $path, $query) = @_;

    $path .= $self->_build_query($query) if $query;

    do {
      print "GET: $path\n";
    } if $DEBUG_REQUESTS_P;

    $self->{rest}->GET($path);

    return $self->_content();
}

sub DELETE {
    my ($self, $path, $query) = @_;

    $path .= $self->_build_query($query) if $query;

    do {
      print "DELETE: $path\n";
    } if $DEBUG_REQUESTS_P;

    $self->{rest}->DELETE($path);

    return $self->_content();
}

sub PUT {
    my ($self, $path, $query, $value, $headers) = @_;

    defined $value
        or croak $self->_error("PUT method's 'value' argument is undefined.");

    $path .= $self->_build_query($query) if $query;

    $headers                   //= {};
    $headers->{'Content-Type'} //= 'application/json;charset=UTF-8';

    $self->{rest}->PUT($path, $self->{json}->encode($value), $headers);

    return $self->_content();
}

sub POST {
    my ($self, $path, $query, $value, $headers) = @_;

    defined $value
        or croak $self->_error("POST method's 'value' argument is undefined.");

    $path .= $self->_build_query($query) if $query;

    $headers                   //= {};
    $headers->{'Content-Type'} //= 'application/json;charset=UTF-8';

    $self->{rest}->POST($path, $self->{json}->encode($value), $headers);

    return $self->_content();
}

sub set_search_iterator {
    my ($self, $params) = @_;

    my %params = ( %$params );  # rebuild the hash to own it

    $params{start} =  0;
    $params{limit}   = 25;

    $self->{iter} = {
        params  => \%params,    # params hash to be used in the next call
        offset  => 0,           # offset of the next issue to be fetched
        results => {            # results of the last call
            start =>  0,
            limit => 25,
            json  => {},
        },
    };

    return;
}

sub next_result {
    my ($self) = @_;
    state $calls = 0;

    my $iter = $self->{iter}
        or croak $self->_error("You must call set_search_iterator before calling next_result");

    my $has_next_page = $iter->{results}{json}{_links}{next};

    if (! $has_next_page && $calls >= 1) {
        # If there is no next page, we've reached the end of the search results
        $self->{iter} = undef;
        return;
      }
    elsif ($iter->{offset} % $iter->{results}{limit} == 0) {
        # If the number of calls to the API so far is 0,
        # OR,
        # if the offset is divisible by the page limit (meaning that we've
        # worked through the current page of responses), we need to:
        #
        # 1. bump the start pointer by LIMIT (unless no calls have been made)
        #
        # 2. fetch the next page of results
        #

        $iter->{params}{start} += $iter->{results}{limit} if $calls > 0;
        $iter->{results}{json}  = $self->GET('/search', $iter->{params});
        $calls++;

        print Dumper $iter if $DEBUG_ITERATORS;
      }
    elsif ($calls == 0) {
      $iter->{params}{start} += $iter->{results}{limit};
    }
    # If neither of the above conditions are true (meaning that we DO have a
    # next page of results but we HAVE NOT yet reached the page offset limit,
    # we need to:
    #
    # + return the next item in the search result ...
    #
    # + the index of which will be the sum of: the offset minus the start, e.g.,
    # if the offset is 78, the start should be 75, meaning the index should be 3
    #

    my $actual_start = ($calls == 0) ? $iter->{results}{start} : $iter->{results}{json}{start};
    return $iter->{results}{json}{results}[$iter->{offset}++ - $actual_start];
}

sub attach_files {
    my ($self, $issueIdOrKey, @files) = @_;

    # We need to violate the REST::Client class encapsulation to implement
    # the HTTP POST method necessary to invoke the /issue/key/attachments
    # REST endpoint because it has to use the form-data Content-Type.

    my $rest = $self->{rest};

    # FIXME: How to attach all files at once?
    foreach my $file (@files) {
        my $response = $rest->getUseragent()->post(
            $rest->getHost . "/issue/$issueIdOrKey/attachments",
            %{$rest->{_headers}},
            'X-Atlassian-Token' => 'nocheck',
            'Content-Type'      => 'form-data',
            'Content'           => [ file => [$file] ],
        );

        $response->is_success
            or croak $self->_error("attach_files($file): " . $response->status_line);
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Confluence::REST - Thin wrapper around Confluence's REST API

=head1 VERSION

version 0.011

=head1 SYNOPSIS

    use Confluence::REST;

    my $confluence = Confluence::REST->new('https://confluence.example.net');

    # Iterate using utility methods
    $confluence->set_search_iterator({
        cql        => 'type = "page" and space = "home"',
    });

    while (my $issue = $confluence->next_result) {
        print "Found issue $issue->{key}\n";
    }

=head1 DESCRIPTION

Confluence::REST - Thin wrapper around Confluence's REST API

CAUTION - THIS IS ALPHA CODE

L<Confluence|http://www.atlassian.com/software/confluence> is a proprietary
wiki from L<Atlassian|http://www.atlassian.com/>.

This module is a thin wrapper around L<Confluence's REST
API|https://developer.atlassian.com/confcloud/confluence-rest-api-39985291.html>,
which is superseding its old SOAP API.  (If you want to interact with
the SOAP API, there's another Perl module called
L<Confluence::Client::XMLRPC|https://github.com/heikojansen/confluence-client-xmlrpc>.

This code is basically L<JIRA::REST|metacpan.org/pod/JIRA::REST> with
some tweaks to get it to work with the Confluence REST API.

Copyright (c) 2013 by CPqD (http://www.cpqd.com.br/).
Copyright (c) 2016 (Changes to adapt to Confluence REST APIs) by Rich Loveland.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 UTILITY METHODS

This module provides a few utility methods.

=head2 B<set_search_iterator> PARAMS

Sets up an iterator for the search specified by the hash-ref PARAMS. It must
be called before calls to B<next_result>.

PARAMS must conform with the query parameters allowed for the
C</rest/api/2/search> JIRA REST endpoint.

=head2 B<next_result>

This must be called after a call to B<set_search_iterator>. Each call
returns a reference to the next issue from the filter. When there are no
more issues it returns undef.

Using the set_search_iterator/next_result utility methods you can iterate
through large sets of issues without worrying about the startAt/total/offset
attributes in the response from the /search REST endpoint. These methods
implement the "paging" algorithm needed to work with those attributes.

=head1 SEE ALSO

=over

=item * C<REST::Client>

JIRA::REST uses a REST::Client object to perform the low-level interactions.

=item * C<JIRA::REST>

This code is basically L<JIRA::REST|https://metacpan.org/pod/JIRA::REST> with
some tweaks to get it to work with the Confluence REST API.

=back

=head1 REPOSITORY

L<https://github.com/rmloveland/Confluence-REST>

=head1 AUTHOR

Richard M. Loveland <rloveland@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by CPqD <www.cpqd.com.br>.
Changes to adapt to Confluence REST APIs copyright (c) 2016 by Rich Loveland.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
