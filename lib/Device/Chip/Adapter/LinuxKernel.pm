package Device::Chip::Adapter::LinuxKernel;

use strict;
use warnings;
use base qw( Device::Chip::Adapter );
use Carp qw/croak/;

our $VERSION = "0.000002"; # Pre-versioning systems release.

our $__TESTDIR=""; # blank unless we're being pointed at a test setup

=head1 NAME

C<Device::Chip::Adapter::LinuxKernel> - A C<Device::Chip::Adapter> implementation

=head1 DESCRIPTION

This class implements the C<Device::Chip::Adapter> interface for the I<LinuxKernel>,
allowing an instance of L<Device::Chip> driver to communicate with the actual
chip hardware by using the Linux Kernel interfaces for GPIO, I2C (SMbus), and SPI.
Suitble for use on any Linux system including Raspberry PI (RPI), Beaglebone, Banana PI
or any other single board computer that exposes IO via the standard Linux Kernel
interfaces.

=head1 CONSTRUCTOR

=cut

=head2 new

   $adapter = Device::Chip::Adapter::LinuxKernel->new( %args )

Returns a new instance of a C<Device::Chip::Adapter::LinuxKernel>.

=head1 KNOWN ISSUES

=over

=item I2C reading likely doesn't work properly

=item GPIO performance is probably horrendous.  We re-open the /value file in sysfs over and over for every action.  This could be better by storing the filehandles

=back

=head1 PLANS AHEAD

I'm going to release a companion module to this for Raspberry PI devices.  
It'll automatically detect which set of hardware you're on and select the appropriate busses for you.
I'll also be working to add "interrupt" support for the GPIO so that you can use C<poll(2)> or C<select(2)> to get a trigger on edge detection on some GPIO devices.

=cut

sub new {
   my $class = shift;

   # TODO not sure what I'll need to take here yet
   
   return bless({}, $class);
}

sub new_from_description {
   my $class = shift;
   my %args = @_;

   # TODO what does this do?
   return bless({}, $class);
}


# TODO these need to take arguments, i.e. what GPIO?
sub make_protocol_GPIO {
   my $self = shift;

   Device::Chip::Adapter::LinuxKernel::_GPIO->new();
}

sub make_protocol_SPI {
   my $self = shift;

   die 'SPI unsupported currently';
}

sub make_protocol_I2C {
    my $self = shift;
    
    Device::Chip::Adapter::LinuxKernel::_I2C->new();
}

sub shutdown {
   my $self = shift;
   
   # delete the interfaces?
}

package
   Device::Chip::Adapter::LinuxKernel::_base;

use Carp;

sub new {
   my $class = shift;

   bless { }, $class;
}

# Most modes have no GPIO on this system
sub list_gpios { return qw( ) }

sub write_gpios {
   my $self = shift;
   my ( $gpios ) = @_;

   foreach my $pin ( keys %$gpios ) {
         croak "Unrecognised GPIO pin name $pin";
   }
}

sub read_gpios {
   my $self = shift;
   my ( $gpios ) = @_;

   my @f;
   foreach my $pin ( @$gpios ) {
     croak "Unrecognised GPIO pin name $pin";
   }
}

# there's no more efficient way to tris_gpios than just read and ignore the result
sub tris_gpios
{
   my $self = shift;
   $self->read_gpios->then_done();
}

package
    Device::Chip::Adapter::LinuxKernel::_GPIO;
    
use base qw( Device::Chip::Adapter::LinuxKernel::_base );
use Carp qw/croak/;

sub configure {
    my $self = shift;
    my %args = @_;

    $self->{gpiostate} = $self->_get_exported(); # get the already exported gpio
    $self->{unexport_on_shutdown} = !!delete $args{unexport}; # Should we unexport all the gpio when we're done?

    croak "Unrecognised configuration options: " . join( ", ", keys %args ) if %args;

    return $self;
}

sub _read_gpio_info {
    my $self = shift;
    my ($gpio) = @_;
    my %info;
    
    for my $f (qw/direction edge active_low/) {
        local $/;
      
        my $fn = $__TESTDIR."/sys/class/gpio/$gpio/$f";
        if (-f $fn) { # these won't always exist
            open (my $fh, "<", ) or die "Couldn't open GPIO data $gpio/$f: $!";
            $info{$f} = <$fh>;
            close($fh);
        }
    }
    
    return \%info;
}

sub _get_exported {
    my $self = shift;
    my @sysfs_list = $self->_get_sysfs_list;
    
    # Give back a hash for all the gpios
    return +{map {$_ => {_export_at_start => 1, %{$self->_read_gpio_info($_)}}} grep {!/gpiochip/} @sysfs_list};
}

sub _get_sysfs_list {
    opendir(my $sysfs, $__TESTDIR."/sys/class/gpio/") or die "Couldn't open sysfs GPIO list: $!";
    my @list = grep {!/^(un)?export$/} readdir $sysfs;
    closedir($sysfs);
    
    return @list; # TODO maybe some memoization is appropriate
}

sub _read_gpiochip_info {
    my $self = shift;
    my ($chip) = @_;
    my %info;
    
    for my $f (qw/ngpio base label/) {
      local $/;
      
      open (my $fh, "<", $__TESTDIR."/sys/class/gpio/$chip/$f") or die "Couldn't open GPIOCHIP data $chip/$f: $!";
      $info{$f} = <$fh>;
      close($fh);
    }
    
    return \%info;
}

# TODO this needs to get it from SysFS
sub list_gpios {
    my $self = shift;
    # TODO make this sort better.  I just can't think of what it should be.
    my @chips = sort {my ($l, $r) = ($a =~ /(\d+)/, $b =~ /(\d+)/); $l <=> $r}
                grep {/gpiochip/}
                $self->_get_sysfs_list();
                
    my $lastgpiochip = $chips[-1];
    
    if ($lastgpiochip) {
        # SysFS interface numbers them all from 0 to the end, so we can generate a list of them based off the final one
        my $lastgpiochip_info = $self->_read_gpiochip_info($lastgpiochip);
        
        my $count = $lastgpiochip_info->{base} + $lastgpiochip_info->{ngpio};
        
        return map {"gpio".$_} 0..$count-1;
    } else {
        return ();
    }
}

sub _export_gpio {
    my $self = shift;
    my ($gpio) = @_;
    
    # Already exported, nothing to do
    return if ($self->{gpiostate}{$gpio});
    
    # TODO this needs to support aliases
    my ($gpio_num) = ($gpio =~ /gpio(\d+)/);
    open(my $fh, ">", $__TESTDIR."/sys/class/gpio/export") or die "Couldn't export $gpio via sysfs: $!";
    print $fh $gpio_num, "\n";
    close($fh);
    
    $self->{gpiostate}{$gpio} = $self->_read_gpio_info($gpio);
}

sub _set_gpio_direction {
    my $self = shift;
    my ($gpio, $direction) = @_; # TODO support aliases
    
    # TODO check direction for correct values
    
    $self->_export_gpio($gpio);
    die "GPIO '$gpio' doesn't support direction change" unless (defined $self->{gpiostate}{$gpio}{direction});
    
    open(my $fh, ">", $__TESTDIR."/sys/class/gpio/$gpio/direction") or die "Couldn't change direction of $gpio: $!";
    print $fh $direction, "\n";
    close($fh);
}

sub _set_gpio_value {
    my $self = shift;
    my ($gpio, $value) = @_;
    
    $self->_export_gpio($gpio);
    
    # TODO keep FH around for faster performance
    open(my $fh, ">", $__TESTDIR."/sys/class/gpio/$gpio/value") or die "Can't write a value to GPIO $gpio (probably input only): $!";
    print $fh ($value ? 1 : 0);
    close($fh);
}

sub _read_gpio_value {
    my $self = shift;
    my ($gpio) = @_;
    $self->_export_gpio($gpio);
    
    # TODO keep FH around for faster performance
    open(my $fh, "<", $__TESTDIR."/sys/class/gpio/$gpio/value") or die "Can't write a value to GPIO $gpio (probably input only): $!";
    my $value = <$fh>;
    close($fh);
    
    return 0+$fh; # make perl get rid of the \n for us
}

# TODO make this do something, also give it an interface
sub _set_edge_trigger {
}

sub _unexport_gpio {
}

sub write_gpios {
    my ($self) = shift;
    my ($gpios) = @_;
    
    for my $gpio (keys %$gpios) {
        $self->_set_gpio_value($gpios->{$gpio});
    }
    
    Future->done
}

sub read_gpios {
    my ($self) = shift;
    my ($gpios) = @_;
    
    Future->done({map {$_ => $self->_read_gpio_value} @$gpios});
}

package 
    Device::Chip::Adapter::LinuxKernel::_I2C;

use base qw( Device::Chip::Adapter::LinuxKernel::_base );
use Carp qw/croak/;
use Device::SMBus;

sub configure {
    my $self = shift;
    my %args = @_;

    $self->{address} = delete $args{addr};
    # $self->{max_rate} = delete $args{max_bitrate}; # We're unable to affect this from userland it seems
    $self->{bus} = delete $args{bus}; # i2c-0, ...
    
    croak "Missing required parameter 'bus'" unless defined $self->{bus};
    croak "Missing required parameter 'addr'" unless defined $self->{address};
        
    croak "Unrecognised configuration options: " . join( ", ", keys %args ) if %args;

    $self->{smbus} = Device::SMBus->new(
        I2CBusDevicePath => $self->{bus},
        I2CDeviceAddress => $self->{address},
    );

    return $self;
}

sub write {
    my $self = shift;
    my ($bytes_out) = @_;
    my @bytes = unpack "C*", $bytes_out; # unpack it into an array for Device::SMBus
    
    my $register = shift @bytes; # Not always technically a register, but 99% of things do work that way.
    
    $self->{smbus}->writeBlockData($register, \@bytes);
    
    Future->done;
}

sub write_then_read {    # TODO This is probably completely fucked up
    my $self = shift;
    my ($bytes_out, $len_in) = @_;
    my @bytes = unpack "C*", $bytes_out; # unpack it into an array for Device::SMBus

    # Here's the fucked up part.  I don't see how I can get the functionality that I THINK is expected here with Device::SMBus.
    # I'm going to do it this way anyway because it'll probably work for maybe 50% of devices, but there's some i know it won't work
    # properly with.  I'll make patches for Device::SMBus to be able to write a block of data and read the immediate response
    # in the same I2C transaction, which is what I believe this is after.
    my $register = shift @bytes; 
    $self->{smbus}->writeBlockData($register, \@bytes);
    Future->done(pack("C*", $self->{smbus}->readBlockData($register, $len_in)));
}

sub read {
    
}

package
    Device::Chip::Adapter::LinuxKernel::_SPI;


=head1 AUTHOR

Ryan Voots <ryan@voots.org>

=cut

0x55AA;
