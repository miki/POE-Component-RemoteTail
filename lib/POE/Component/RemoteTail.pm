package POE::Component::RemoteTail;

use strict;
use warnings;
use Debug::STDERR;
use POE;
use POE::Wheel::Run;
use POE::Component::RemoteTail::Job;
use Class::Inspector;
use UNIVERSAL::require;

our $VERSION = '0.01008';

sub spawn {
    my $class = shift;
    my $self  = $class->new(@_);

    $self->{alias} ||= "tailer";
    $self->{session_id} =
      POE::Session->create(
        object_states => [ $self => Class::Inspector->methods($class) ], )
      ->ID();

    return $self;
}

sub new {
    my $class = shift;

    return bless {@_}, $class;
}

sub session_id {
    return shift->{session_id};
}

sub job {
    my $self = shift;

    my $job = POE::Component::RemoteTail::Job->new(@_);
    return $job;
}

sub start_tail {
    my ( $self, $kernel, $session, $heap, $arg ) =
      @_[ OBJECT, KERNEL, SESSION, HEAP, ARG0 ];

    $arg->{postback} and $heap->{postback} = $arg->{postback};
    $kernel->post( $session, "_spawn_child" => $arg->{job} );
}

sub stop_tail {
    my ( $self, $kernel, $session, $heap, $arg ) =
      @_[ OBJECT, KERNEL, SESSION, HEAP, ARG0 ];

    my $job = $arg->{job};
    debug("STOP:$job->{id}");
    my $wheel = $heap->{wheel}->{ $job->{id} };
    $wheel->kill(9);
    delete $heap->{wheel}->{ $job->{id} };
    delete $heap->{host}->{ $job->{id} };
    undef $job;
}

sub _start {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    $kernel->alias_set( $self->{alias} );
    $kernel->sig( HUP  => "_stop" );
    $kernel->sig( INT  => "_stop" );
    $kernel->sig( QUIT => "_stop" );
    $kernel->sig( TERM => "_stop" );
}

sub _stop {
    my ( $self, $kernel, $heap ) = @_[ OBJECT, KERNEL, HEAP ];
    my ( $whee_id, $wheel ) = each %{ $heap->{wheel} };
    $wheel and $wheel->kill(9);
}

sub _spawn_child {
    my ( $self, $kernel, $session, $heap, $job, $sender ) =
      @_[ OBJECT, KERNEL, SESSION, HEAP, ARG0, SENDER ];

    # prepare ...
    my $class       = $job->{process_class};
    my $host        = $job->{host};
    my $path        = $job->{path};
    my $user        = $job->{user};
    my $ssh_options = $job->{ssh_options};
    my $add_command = $job->{add_command};

    my $command = "ssh -A";
    $command .= ' ' . $ssh_options if $ssh_options;
    $command .= " $user\@$host \"tail -f $path";
    $command .= ' ' . $add_command if $add_command;
    $command .= '"';

    # default Program ( go on a simple unix command )
    my %program = ( Program => $command );

    # use custom class
    if ( my $class = $job->{process_class} ) {
        $class->require or die(@!);
        $class->new();
        %program = ( Program => sub { $class->process_entry($job) }, );
    }

    $SIG{CHLD} = "IGNORE";

    # run wheel
    my $wheel = POE::Wheel::Run->new(
        %program,
        StdioFilter => POE::Filter::Line->new(),
        StdoutEvent => "_got_child_stdout",
        StderrEvent => "_got_child_stderr",
        CloseEvent  => "_got_child_close",
    );

    my $id = $wheel->ID;
    $heap->{wheel}->{$id} = $wheel;
    $heap->{host}->{$id}  = $host;
    $job->{id}            = $id;
}

sub _got_child_stdout {
    my ( $kernel, $session, $heap, $stdout, $wheel_id ) =
      @_[ KERNEL, SESSION, HEAP, ARG0, ARG1 ];
    debug("STDOUT:$stdout");

    my $host = $heap->{host}->{$wheel_id};

    if ( $heap->{postback} ) {
        $heap->{postback}->( $stdout, $host );
    }
    else {
        print $stdout, $host, "\n";
    }
}

sub _got_child_stderr {
    my $stderr = $_[ARG0];
    debug("STDERR:$stderr");
}

sub _got_child_close {
    my ( $heap, $wheel_id ) = @_[ HEAP, ARG0 ];
    delete $heap->{wheel}->{$wheel_id};
    debug("CLOSE:$wheel_id");
}

1;

__END__

=head1 NAME

POE::Component::RemoteTail - tail to remote server's access_log on ssh connection.

=head1 SYNOPSIS

  use POE;
  use POE::Component::RemoteTail;
  
  my ( $host, $path, $user ) = @target_host_info;
  my $alias = 'Remote_Tail';
  
  # spawn component
  my $tailer = POE::Component::RemoteTail->spawn( alias => $alias );
  
  # create job
  my $job = $tailer->job(
      host          => $host,
      path          => $path,
      user          => $user,
      ssh_options   => $ssh_options, # see POE::Component::RemoteTail::Job
      add_command   => $add_command, # see POE::Component::RemoteTail::Job
  );
  
  # prepare the postback subroutine at main POE session
  POE::Session->create(
      inline_states => {
          _start => sub {
              my ( $kernel, $session ) = @_[ KERNEL, SESSION ];
              # create postback
              my $postback = $session->postback("MyPostback");
  
              # post to execute
              $kernel->post( $alias,
                  "start_tail" => { job => $job, postback => $postback } );
          },
  
          # return to here
          MyPostback => sub {
              my ( $kernel, $session, $data ) = @_[ KERNEL, SESSION, ARG1 ];
              my $log  = $data->[0];
              my $host = $data->[1];
              ... do something ...;
          },
      },
  );
  
  POE::Kernel->run();


=head1 DESCRIPTION

POE::Component::RemoteTail provides some loop events that tailing access_log on remote host.
It replaces "ssh -A user@host tail -f access_log" by the same function.

This moduel does not allow 'PasswordAuthentication'. 
Use RSA or DSA keys, or you must write your Custom Engine with this module.
( ex. POE::Component::RemoteTail::CustomEngine::NetSSHPerl.pm )


=head1 EXAMPLE

If you don't prepare 'postback', PoCo::RemoteTail outputs log data to child process's STDOUT.

  use POE::Component::RemoteTail;
  
  my $tailer = POE::Component::RemoteTail->spawn();
  my $job = $tailer->job( host => $host, path => $path, user => $user );
  POE::Session->create(
      inlines_states => {
          _start => sub {
              $kernel->post($tailer->session_id, "start_tail" => {job => $job}); 
          },
      }
  );
  POE::Kernel->run();


It can tail several servers at the same time.

  use POE::Component::RemoteTail;
  
  my $tailer = POE::Component::RemoteTail->spawn(alias => $alias);

  my $job_1 = $tailer->job( host => $host1, path => $path, user => $user );
  my $job_2 = $tailer->job( host => $host2, path => $path, user => $user );

  POE::Session->create(
      inlines_states => {
          _start => sub {
              my $postback = $session->postback("MyPostback");
              $kernel->post($alias, "start_tail" => {job => $job_1, postback => $postback}); 
              $kernel->post($alias, "start_tail" => {job => $job_2, postback => $postback}); 
              $kernel->delay_add("stop_tail", 10, [ $job_1 ]);
              $kernel->delay_add("stop_tail", 20, [ $job_1 ]);
          },
          MyPostback => sub {
              my ( $kernel, $session, $data ) = @_[ KERNEL, SESSION, ARG1 ];
              my $log  = $data->[0];
              my $host = $data->[1];
              ... do something ...;
          },
          stop_tail => sub {
              my ( $kernel, $session, $arg ) = @_[ KERNEL, SESSION, ARG0 ];
              my $target_job = $arg->[0];
              $kernel->post( $alias, "stop_tail" => {job => $target_job});
          },
      },
  );
  POE::Kernel->run();


=head1 METHOD

=head2 spawn()

=head2 job()

=head2 start_tail()

=head2 stop_tail()

=head2 session_id()

=head2 debug()

=head2 new()

=head1 AUTHOR

Takeshi Miki E<lt>miki@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut
