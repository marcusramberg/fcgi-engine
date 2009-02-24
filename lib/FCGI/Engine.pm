package FCGI::Engine;
use Moose;

use FCGI;
use CGI::Simple;

use MooseX::Daemonize::Pid::File;

use FCGI::Engine::Types;
use FCGI::Engine::ProcManager;

use constant DEBUG => 0;

our $VERSION   = '0.06';
our $AUTHORITY = 'cpan:STEVAN';

with 'MooseX::Getopt',
     'MooseX::Daemonize::Core';

has 'listen' => (
    metaclass   => 'Getopt',
    is          => 'ro',
    isa         => 'FCGI::Engine::Listener',
    coerce      => 1,
    cmd_aliases => 'l',
    predicate   => 'is_listening',
);

has 'nproc' => (
    metaclass   => 'Getopt',
    is          => 'ro',
    isa         => 'Int',
    default     => sub { 1 },
    cmd_aliases => 'n',
);

has 'pidfile' => (
    metaclass   => 'Getopt',
    is          => 'ro',
    isa         => 'MooseX::Daemonize::Pid::File',
    coerce      => 1,
    cmd_aliases => 'p',
    predicate   => 'has_pidfile',
);

has 'detach' => (
    metaclass   => 'Getopt',
    is          => 'ro',
    isa         => 'Bool',
    cmd_flag    => 'daemon',
    cmd_aliases => 'd',
    predicate   => 'should_detach',
);

has 'manager' => (
    metaclass   => 'Getopt',
    is          => 'ro',
    isa         => 'Str',
    default     => sub { 'FCGI::Engine::ProcManager' },
    cmd_aliases => 'M',
);

# options to specify in your script

has 'handler_class' => (
    metaclass => 'NoGetopt',
    is        => 'ro',
    isa       => 'Str | Object',
    required  => 1,
);

has 'handler_method' => (
    metaclass => 'NoGetopt',
    is        => 'ro',
    isa       => 'Str',
    default   => sub { 'handler' },
);

has 'handler_args_builder' => (
    metaclass => 'NoGetopt',
    is        => 'ro',
    isa       => 'CodeRef',
    default   => sub { 
        sub { CGI::Simple->new }
    },
);

has 'pre_fork_init' => (
    metaclass => 'NoGetopt',
    is        => 'ro',
    isa       => 'CodeRef',
    predicate => 'has_pre_fork_init',
);

## methods ...

sub BUILD {
    my $self = shift;

    ($self->has_pidfile)
        || confess "You must specify a pidfile if you are listening"
            if $self->is_listening;
}

sub run {
    my ($self, %addtional_options) = @_;

    $self->pre_fork_init->(%addtional_options) 
        if $self->has_pre_fork_init;

    my $handler_class  = $self->handler_class;
    my $handler_method = $self->handler_method;
    my $handler_args   = $self->handler_args_builder;
        
    Class::MOP::load_class($handler_class) unless blessed $handler_class;

    ($self->handler_class->can($handler_method))
        || confess "The handler class ("
                 . $handler_class
                 . ") does not support the handler method ("
                 . $handler_method
                 . ")";

    my $socket = 0;

    if ($self->is_listening) {
        my $old_umask = umask;
        umask(0);
        $socket = FCGI::OpenSocket($self->listen, 100);
        umask($old_umask);
    }

    my $request = FCGI::Request(
        \*STDIN,
        \*STDOUT,
        \*STDERR,
        \%ENV,
        $socket,
        &FCGI::FAIL_ACCEPT_ON_INTR
    );

    my $proc_manager;

    if ($self->is_listening) {

        $self->daemon_fork && return if $self->detach;

        # make sure any subclasses are loaded ...        
        Class::MOP::load_class($self->manager);

        $proc_manager = $self->manager->new({
            n_processes => $self->nproc,
            pidfile     => $self->pidfile,
            %addtional_options
        });

        $self->daemon_detach(
            # Not sure we need this ...
            no_double_fork       => 1,
            # we definetely need this ...
            dont_close_all_files => 1,
        ) if $self->detach;
        
        $proc_manager->manage;   
    }

    while ($request->Accept() >= 0) {
        
        $proc_manager && $proc_manager->pre_dispatch;

        # Cargo-culted from Catalyst::Engine::FastCGI ...
        if ( $ENV{SERVER_SOFTWARE} && $ENV{SERVER_SOFTWARE} =~ /lighttpd/ ) {
            $ENV{PATH_INFO} ||= delete $ENV{SCRIPT_NAME};
        }

        $handler_class->$handler_method( $handler_args->() );

        $proc_manager && $proc_manager->post_dispatch;
    }
}

1;

__END__

=pod

=head1 NAME

FCGI::Engine - A flexible engine for running FCGI-based applications

=head1 SYNOPSIS

  # in scripts/my_web_app_fcgi.pl
  use strict;
  use warnings;
  
  use FCGI::Engine;
  
  FCGI::Engine->new_with_options(
      handler_class  => 'My::Web::Application',
      handler_method => 'run',
      pre_fork_init  => sub {
          require('my_web_app_startup.pl');
      }
  )->run;

  # run as normal FCGI script
  perl scripts/my_web_app_fcgi.pl

  # run as standalone FCGI server
  perl scripts/my_web_app_fcgi.pl --nproc 10 --pidfile /tmp/my_app.pid \
                                  --listen /tmp/my_app.socket --daemon

  # see also FCGI::Engine::Manager for managing 
  # multiple FastCGI backends under one script

=head1 IMPORTANT NOTE

This is an early release of this module, it is intended to fill the 
need for a better set of FastCGI tools. At this point it still lacks
good documentation and a few of the bits still need some work. However
it is reasonably stable and I am using it actively at $work. If you have
any questions about this module feel free to contact me. 

The API for L<FCGI::Engine> is probably the only one which will not change 
(since is really just emulates the L<Catalyst::Engine::FCGI> API), all 
other modules in this distro are subject to change at this point.

=head1 DESCRIPTION

This module helps manage FCGI based web applications by providing a 
wrapper which handles most of the low-level FCGI details for you. It
can run FCGI programs as simple scripts or as full standalone 
socket based servers who are managed by L<FCGI::Engine::ProcManager>.

The code is largely based (*cough* stolen *cough*) on the 
L<Catalyst::Engine::FastCGI> module, and provides a  command line 
interface which is compatible with that module. But of course it 
does not require L<Catalyst> or anything L<Catalyst> related. So 
you can use this module with your L<CGI::Application>-based web 
application or any other L<Random::Web::Framework>-based web app.

=head2 Using with Catalyst or other web frameworks

This module (FCGI::Engine) is B<not> a replacement for L<Catalyst::Engine::FastCGI>
but instead the L<FCGI::Engine::Manager> (and all it's configuration tools) can be 
used to manager L<Catalyst> apps as well as FCGI::Engine based applications. For 
example, at work we have an application which has 6 different FCGI backends running.
Three of them use an ancient in-house web framework with simple FCGI::Engine wrappers, 
one which uses L<CGI::Application> and an FCGI::Engine wrapper and then two L<Catalyst>
applications. They all happily and peacefully coexist and are all managed with the 
same L<FCGI::Engine::Manager> script.

=head2 Note about CGI.pm usage

This module uses L<CGI::Simple> as a sane replacement for CGI.pm, it will pass in
a L<CGI::Simple> instance to your chosen C<handler_method> for you, so there is no 
need to create your own instance of it. There have been a few cases from users who
have had bad interactions with CGI.pm and the instance of L<CGI::Simple> we create
for you, so before you spend hours looking for bugs in your app, check for this 
first instead.

If you want to change this behavior and not use L<CGI::Simple> then you can 
override this using the C<handler_args_builder> option, see the docs on that 
below for more details.

=head1 CAVEAT

This module is *NIX B<only>, it definitely does not work on Windows
and I have no intention of making it do so. Sorry.

=head1 PARAMETERS

=head2 Command Line

This module uses L<MooseX::Getopt> for command line parameter
handling and validation.

All parameters are currently optional, but some parameters
depend on one another.

=over 4

=item I<--listen -l>

This should be a file path where the unix domain socket file
should live. If this parameter is specified, then you B<must> 
also specify a location for the pidfile.

=item I<--nproc -n>

This should be an integer specifying the number of FCGI processes
that L<FCGI::Engine::ProcManager> should start up. The default is 1.

=item I<--pidfile -p>

This should be a file path where your pidfile should live. This 
parameter is only used if the I<listen> parameter is specified.

=item I<--daemon -d>

This is a boolean parameter and has no argument, it is either 
used or not. It determines if the script should daemonize itself.
This parameter only used if the I<listen> parameter is specified.

=item I<--manager -m>

This allows you to pass the name of a L<FCGI::ProcManager> subclass 
to use. The default is to use L<FCGI::Engine::ProcManager>, and any value
passed to this parameter B<must> be a subclass of L<FCGI::ProcManager>.

=back

=head2 Constructor

In addition to the command line parameters, there are a couple 
parameters that the constuctor expects. 

=over 4

=item I<handler_class>

This is expected to be a class name, which will be used inside 
the request loop to dispatch your web application.

=item I<handler_method>

This is the class method to be called on the I<handler_class>
to server as a dispatch entry point to your web application. It
will default to C<handler>.

=item I<handler_args_builder>

This must be a CODE ref that when called produces the arguments 
to pass to the I<handler_method>. It defaults to a sub which 
returns a L<CGI::Simple> object.

=item I<pre_fork_init>

This is an optional CODE reference which will be executed prior
to the request loop, and in a multi-proc context, prior to any 
forking (so as to take advantage of OS COW features).

=back

=head1 METHODS

=head2 Command Line Related

=over 4

=item B<listen>

Returns the value passed on the command line with I<--listen>.
This will return a L<Path::Class::File> object.

=item B<is_listening>

A predicate used to determine if the I<--listen> parameter was 
specified.

=item B<nproc>

Returns the value passed on the command line with I<--nproc>.

=item B<pidfile>

Returns the value passed on the command line with I<--pidfile>.
This will return a L<Path::Class::File> object.

=item B<has_pidfile>

A predicate used to determine if the I<--pidfile> parameter was 
specified.

=item B<detach>

Returns the value passed on the command line with I<--daemon>.

=item B<should_detach>

A predicate used to determine if the I<--daemon> parameter was 
specified.

=item B<manager>

Returns the value passed on the command line with I<--manager>.

=back

=head2 Inspection

=over 4

=item B<has_pre_fork_init>

A predicate telling you if anything was passed to the 
I<pre_fork_init> constructor parameter.

=back

=head2 Important Stuff

=over 4

=item B<run (%addtional_options)>

Call this to start the show. 

It passes the C<%addtional_options> arguments to both the 
C<pre_fork_init> sub and as constructor args to the 
C<proc_manager>. 

=back

=head2 Other Stuff

=over 4

=item B<BUILD>

This is the L<Moose> BUILD method, it checks some of 
our parameters to be sure all is sane.

=item B<meta>

This returns the L<Moose> metaclass assocaited with 
this class.

=back

=head1 SEE ALSO

=over 4

=item L<Catalyst::Engine::FastCGI>

I took all the guts of that module and squished them around a bit and 
stuffed them in here. 

=item L<MooseX::Getopt>

=item L<FCGI::ProcManager>

I refactored this module and renamed it L<FCGI::Engine::ProcManager>, 
which is now included in this distro.

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

Contributions from:

Bradley C. Bailey

Brian Cassidy

=head1 COPYRIGHT AND LICENSE

Copyright 2007-2008 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


