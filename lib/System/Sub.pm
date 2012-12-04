use strict;
use warnings;
package System::Sub;

use File::Which ();
use Sub::Name 'subname';
use Symbol 'gensym';
use IPC::Run qw(start finish);
our @CARP_NOT;

my %OPTIONS = (
    # Value is the expected ref of the option value
    # undef is no value
    '>' => '',
    '<' => '',
    'ENV' => 'HASH',
);

sub _croak
{
    require Carp;
    goto &Carp::croak
}

sub _carp
{
    require Carp;
    goto &Carp::carp
}

sub import
{
    my $pkg = (caller)[0];
    shift;

    while (@_) {
        my $name = shift;
        # Must be a scalar
        _croak "invalid arg: SCALAR expected" unless defined ref $name && ! ref $name;
        my $fq_name;
        if (index($name, ':') > 0) {
            $fq_name = $name;
            $name = substr($fq_name, 1+rindex($fq_name, ':'));
        } else {
            $fq_name = $pkg.'::'.$name;
        }

        my $cmd = $name;
        my $args;
        my %options;
        if (@_ && ref $_[0]) {
            my $options = shift;

            while (@$options) {
                my $opt = shift @$options;
                (my $opt_short = $opt) =~ s/^[\$\@]//;
                if ($opt eq '--') {
                    _croak 'duplicate @ARGV' if $args;
                    $args = $options;
                    last
                } elsif ($opt =~ /^\$?0$/) { # $0
                    $cmd = shift @$options;
                } elsif ($opt =~ /^\@?ARGV$/) { # @ARGV
                    _croak "$name: invalid @ARGV" if ref($options->[0]) ne 'ARRAY';
                    $args = shift @$options;
                } elsif (! exists ($OPTIONS{$opt})) {
                    _carp "$name: unknown option $opt";
                } elsif (defined $OPTIONS{$opt_short}) {
                    my $value = shift @$options;
                    unless (defined $value) {
                        _croak "$name: value expected for option $opt"
                    } elsif (ref($value) ne $OPTIONS{$opt_short}) {
                        _croak "$name: invalid value for option $opt"
                    }
                    $options{$opt_short} = $value;
                } else {
                    $options{$opt_short} = 1;
                }
            }
        }

        unless (File::Spec->file_name_is_absolute($cmd)) {
            my ($vol, $dir, undef) = File::Spec->splitpath($cmd);
            if (length($vol)+length($dir) == 0) {
                $cmd = File::Which::which($cmd);
            }
        }

        my $sub = defined($cmd)
                ? _build_sub($name, [ $cmd, ($args ? @$args : ())], \%options)
                : sub { _croak "'$name' not found in PATH" };

        no strict 'refs';
        *{$fq_name} = subname $fq_name, $sub;
    }
}

sub _build_sub
{
    my ($name, $cmd, $options) = @_;

    return sub {
        my ($input, $output_cb);
        $output_cb = pop if ref $_[$#_] eq 'CODE';
        $input = pop if ref $_[$#_];
        my @cmd = (@$cmd, @_);
        print join(' ', '[', (map { / / ? qq{"$_"} : $_ } @cmd), ']'), "\n";
        my $h;
        my $out = gensym; # IPC::Run needs GLOBs

        # errors from IPC::Run must be reported as comming from our
        # caller, not from here
        local @IPC::Run::CARP_NOT = (@IPC::Run::CARP_NOT, __PACKAGE__);

        local %ENV = (%ENV, %{$options->{ENV}}) if exists $options->{ENV};

        if ($input) {
            my $in = gensym;
            $h = start \@cmd,
                       '<pipe', $in, '>pipe', $out or _croak $!;
            binmode($in, $options->{'>'}) if exists $options->{'>'};
            if (ref $input eq 'ARRAY') {
                print $in map { "$_$/" } @$input;
            } elsif (ref $input eq 'SCALAR') {
                # use ${$input}} as raw input
                print $in $$input;
            }
            close $in;
        } else {
            $h = start \@cmd, \undef, '>pipe', $out or _croak $!;
        }
        binmode($out, $options->{'<'}) if exists $options->{'<'};
        if (wantarray) {
            my @output;
            if ($output_cb) {
                while (<$out>) {
                    chomp;
                    push @output, $output_cb->($_)
                }
            } else {
                while (<$out>) {
                    chomp;
                    push @output, $_
                }
            }
            close $out;
            finish $h;
            _croak "$name error ".($?>>8) if $? >> 8;
            return @output
        } elsif (defined wantarray) {
            # Only the first line
            my $output;
            defined($output = <$out>) and chomp $output;
            close $out;
            finish $h;
            _croak "$name error ".($?>>8) if $? >> 8;
            _croak "no output" unless defined $output;
            return $output
        } else { # void context
            if ($output_cb) {
                while (<$out>) {
                    chomp;
                    $output_cb->($_)
                }
            }
            close $out;
            finish $h;
            _croak "$name error ".($?>>8) if $? >> 8;
            return
        }
    }
}


1;
__END__

=encoding utf-8

=head1 NAME

System::Sub - Wrap external command with a DWIM sub

=head1 SYNOPSIS

    use System::Sub 'hostname';  # Just an example (use Sys::Hostname instead)

    # Scalar context : returns the first line of the output, without the
    # line separator
    my $hostname = hostname;

    # List context : returns a list of lines without their line separator
    use System::Sub 'ls';
    my @files = ls '-a';

    # Process line by line
    ls -a => sub {
        push @files, $_[0];
    };

    # Import with options
    use System::Sub ssh => [ '$0' => '/usr/bin/ssh',
                             '@ARGV' => [ qw< -o RequestTTY=no > ] ];

    # Handle exit codes
    use System::Sub 'zenity'; # a GTK+ dialog display
    eval {
        zenity --question
            => --text => 'How are you today?'
            => --ok-label => 'Fine!'
            => --cancel-label => 'Tired.'
    };
    given ($? >> 8) {
        when (0) {
        }
        when (1) {
        }
    }

=head1 DESCRIPTION

See also C<L<System::Sub::AutoLoad>> for even simpler usage.

C<System::Sub> declares in your package a sub that wraps the call to an external
program. The return value is line(s) dependending on context (C<wantarray>).

This may be what you need if you want to run external commands as easily
as from a Unix shell script but with a perl-ish feel (contextual output). So
this is not a universal module for running external programs (like L<IPC::Run>)
but instead a simpler interface for a common style of external programs.

C<System::Sub> may be useful if:

=over 4

=item *

you want to run the command synchronously (like C<system> or backquotes)

=item *

the command

=over 4

=item -
non-interactive (all the input is fed at start)

=item -
input is C<@ARGV> and C<STDIN>

=item -
output is C<STDOUT>

=item -
the exit code is what matters for errors

=item -
C<STDERR> will not be captured, and will go to C<STDERR> of your program.

=back

=back

The underlying implementation is currently L<IPC::Run>, but there is no
garantee that this will stay that way. L<IPC::Run> works well enough on both
Unix and Win32, but it has its own bugs and is very slow.

=head1 IMPORT OPTIONS

Options can be set for the sub by passing an ARRAY just after the sub name
on the C<use System::Sub> line.

The sigil (C<$>, C<@>, C<%>) is optional.

=over 4

=item *

C<$0>: the path to the executable file. It will be expanded from PATH if it
doesn't contain a directory separator.

=item *

C<@ARGV>: command arguments that will be inserted before the arguments given
to the sub. This is useful if the command always require a basic set of
arguments.

=item *

C<%ENV>: environment variables to set for the command.

=item *

C<E<gt>>: I/O layers for the data fed to the command.

=item *

C<E<lt>>: I/O layers for the data read from the command output.

=back

=head1 SUB USAGE

=head2 Arguments

The scalar arguments of the sub are directly passed as arguments of the
command.

The queue of the arguments may contain values of the following type (see
L<perlfunc/ref>):

=over 4

=item * C<CODE>

A sub that will be called for each line of the output. The argument is the
C<chomp>-ed line.

    sub {
        my ($line)
    }

This argument must always be the last one.

=item * C<REF>

A reference to a scalar containing the full input of the command.

=item * C<ARRAY>

A reference to an array containing the lines of the input of the command.
C<\n> will be appended at the end of each line.

=head2 Return value(s)

=over 4

=item *

Scalar context

Returns just the first line (based on C<$/>), chomped or undef if no output.

=item *

List context

Returns a list of the lines of the output, based C<$/>.
The end-of-line chars (C<$/> are not in the output.

=item *

Void context

If you do not specify a callback, the behavior is currently unspecified
(suggestions welcome).

=back

=head1 SEE ALSO

=over 4

=item * L<perlipc>, L<perlfaq8>

=item * L<IPC::Run>

=item * L<AnyEvent::Util::run|AnyEvent::Util>

=item * L<System::Command>

=item * L<Sys::Cmd>

=item * L<Proc::Lite>

=item * L<IPC::Open3>

=item * L<Sys::Cmd>

=item * L<System>

=item * L<System2>

=item * L<IPC::Cmd>

=back

=head1 TRIVIA

I dreamed about such a facility for a long time. I even worked for two years on
a ksh framework that I created from scratch just because at the start of the
project I didn't dare to bet on Perl because of the lack of readability of the
code when most of the work is running other programs.

After that project I never really had the need to run the same command
in many places of the code, and in many different ways. Until I had the need
to wrap L<Git|http://git-scm.org/> in the
L<release|https://github.com/github-keygen/> script of my
L<github-keygen|https://github.com/github-keygen> project. I wrote the first
version of the wrapper there, and quickly extracted it as this module.
So, here is it!

Last but not least, the pun in the package name is intended.

=head1 AUTHOR

Olivier MenguE<eacute>, C<dolmen@cpan.org>.

=head1 COPYRIGHT & LICENSE

Copyright E<copy> 2012 Olivier MenguE<eacute>.

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl 5 itself.

=cut

# vim:set et sw=4 sts=4:
