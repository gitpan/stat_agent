#!/usr/bin/perl -w
# ***************************************************************************
# *   stat_agent.pl                                                         *
# *                                                                         * 
# *   Copyright (C) 2009 by Marc Koderer /                                  *
# *                         LHS Telekommunikations GmbH & Co. KG            *
# *                                                                         * 
# *   This program is free software; you can redistribute it and/or modify  *
# *   it under the terms of the GNU General Public License as published by  *
# *   the Free Software Foundation; either version 2 of the License, or     *
# *   (at your option) any later version.                                   *
# *                                                                         *
# *   This program is distributed in the hope that it will be useful,       *
# *   but WITHOUT ANY WARRANTY; without even the implied warranty of        *
# *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *
# *   GNU General Public License for more details.                          *
# *                                                                         *
# *   You should have received a copy of the GNU General Public License     *
# *   along with this program; if not, write to the                         *
# *   Free Software Foundation, Inc.,                                       *
# *   59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.             *
# ***************************************************************************

=head1 NAME

stat_agent.pl - dim_STAT monitoring agent

=head1 SCRIPT CATEGORIES

UNIX/System_administration

=head1 PREREQUISITES

This script requires C<IO::Socket> and C<Getopt::Long>

=head1 OSNAMES

C<linux> and all UNIX systems

=head1 SYNOPSIS

 stat_agent.pl -f access_file [-p port] [-l logfie] [-d] [-v]

 stat_agent --port 5000 -f access

=head1 README

This script can be used as a replacement of the original dim_STAT
STATsrv monitoring agent.

=head1 DESCRIPTION

This script opens the specified TCP port and waits for 
connections of the dim_STAT server.

This script was tested with dim_STAT Version 8.2. 

Improvements:

=over 2

=item * Platform independent 

Should run under all UNIX/Linux systems. 

=item * More restricted security behavior

=over 3

=item - The access file is checked if specified command is executable 

(if not it's not added to the executable command stack).

=item - All special characters in the command parameter are deleted

(except '_', '/', '-' and ' '). 

=item - It's possible specify a user for each executable command. 

=back

=back

The options are as follows:

=over 12

=item C<--port, -p>    

TCP port (default 5000) 

=item C<--file, -f>    

Command access file with the usually STATsrv syntax, e.g.:

  # Usable from any hosts
  command  vmstat      /usr/bin/vmstat    
  # Usable from .50 and .51 only 
  access 10.10.10.50
  access 10.10.10.51
  command  mpstat      /usr/bin/mpstat    
  command  netstat     /usr/bin/netstat   

To execute a command by a specific user the following syntax has to be used:

  command  jack:netstat   /usr/bin/netstat    
  command  jane:mpstat    /usr/bin/mpstat

To do so the current user must be allowed to "su" to the specified
user without a password.

=item C<--daemon, -d>        

Run program as unix daemon

=item C<--log, -l>

Specifies the log file (default STDOUT)

=item C<--verbose, -v>    

Verbose mode

=back

=head1 INSTALLATION

To replace the existing STATsrv agent with this version shutdown all running
STATsrv agents and copy the stat-agent.pl script to your STATsrv installation:

  /etc/STATsrv/STAT-service stop
  cp stat-agent.pl /etc/STATsrv/bin

Replace the old STAT-service script with this one:

  cp STAT-service /etc/STATsrv

=head1 SEE ALSO

The dim_STAT project: http://dimitrik.free.fr/

=head1 COPYRIGHT

Copyright (C) 2009 by Marc Koderer/LHS Telekommunikations GmbH & Co. KG

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License.

=cut
use strict;
use IO::Socket;
use Getopt::Long;
our $VERSION = '0.10';
my $SOCK_BUF = 1024;
my $verbose = 0;
my $port = 5000;
my $access_file = undef;
my $daemonize = 0;
our $srv_socket;
our $cmd_socket;
my $log_file = '';
my $unit_test_p_cfg = 0;
&usage if ($#ARGV == -1);
# don't create zombies 
$SIG{CHLD} = 'IGNORE';
# Kill the process group
$SIG{TERM} = sub{kill 'INT'=> -$$; 
                 exit;};
GetOptions ("port|p=i" => \$port,    
            "file|f=s" => \$access_file,
            "daemon|d" => \$daemonize,
            "log|l=s"  => \$log_file,
            "verbose"  => \$verbose,
            "help|h"   => \&usage,
            "unit-test-only-config" 
                       => \$unit_test_p_cfg); 

&usage unless ($access_file);
my $pid_file = "/tmp/stat_agent_$port.pid";
if ($daemonize){
    umask 0;
    open STDIN,  '/dev/null'   or die "Can't read /dev/null: $!";
    open STDOUT, '/dev/null';
    open STDERR, '/dev/null';
    my $pid = fork;
    exit 0 if $pid;
}

if ($log_file){
    open STDOUT, ">$log_file";
    open STDERR, ">$log_file";
}

my $access_cfg = read_cfg ($access_file);
# only print config and exit 
if ($unit_test_p_cfg){
    foreach my $host (keys %$access_cfg){
        print "host: $host\n";
          foreach my $cmd (keys %{$access_cfg->{$host}}){
            print "$cmd ".$access_cfg->{$host}{$cmd}."\n";  
          }
    }
   exit 0; 
}

$srv_socket = new IO::Socket::INET (
                                  LocalPort => $port,
                                  Proto     => 'tcp',
                                  Listen    => 10,
                                  Reuse     => 1,
                                 );
die "Could not create socket: -> $!\n" unless $srv_socket;
print "Server listening on port $port...\n";

# set a process group  
setpgrp;

# write pid file
my $pid_fh;
open ($pid_fh, ">$pid_file") || die "Could not create pid file $pid_file";
print $pid_fh "$$\n";
close $pid_fh;

while (1){
    $cmd_socket = $srv_socket->accept();
    $cmd_socket -> autoflush(1);
    my $pid = fork();
    
    unless ($pid){ #Child process
        close ($srv_socket);
        my $command_line = '';
        sysread ($cmd_socket, $command_line, $SOCK_BUF);
        unless (defined ($command_line)){
            warn "No command is send";
            close $cmd_socket;
            exit;
        }
        my $addr = $cmd_socket -> peerhost();
        log_line ("Incomming connection $addr\n");
        log_verbose ("Sended statement: $command_line\n") if $verbose;
        if ($command_line eq 'STAT_LIST'){
            syswrite( $cmd_socket, "STAT *** LIST COMMAND (STAT_LIST)\n", 
                      $SOCK_BUF);
            if ($verbose){
                log_verbose ("### STAT *** LIST COMMAND (STAT_LIST)\n") ;
            }
            if (exists $access_cfg -> {"ALL_HOSTS"}){
                foreach (keys %{$access_cfg -> {"ALL_HOSTS"}}){
                    next if $_ =~ /#USER#/;
                    log_verbose ("### STAT: $_\n") if $verbose;
                    syswrite( $cmd_socket, "STAT: $_\n", $SOCK_BUF);
                }
            }
            if (exists $access_cfg -> {$addr}){
                foreach (keys %{$access_cfg -> {$addr}}){
                    next if $_ =~ /#USER#/;
                    log_verbose ("### STAT: $_\n") if $verbose;
                    syswrite ($cmd_socket, "STAT: $_\n", $SOCK_BUF);
                }
            }
            syswrite ($cmd_socket, "STAT *** LIST END (STAT_LIST)\n",
                      $SOCK_BUF);
            log_verbose ("### STAT *** LIST END (STAT_LIST)\n") if $verbose;
            close $cmd_socket;
            exit ;
        }
    
        # deleting all characters that aren't:
        #   - Alphanumerics and '_' 
        #   - '-'
        #   - '/'
        #   - ' '
        $command_line =~ s /[^\w\-\.\/ ]//g;
    
        unless ($command_line =~ /^([^ ]+) *(.*)/){
            warn "Bad syntax $command_line";
            close $cmd_socket;
            exit;
        }
        my ($cmd, $args) = ($1, $2);
        
        log_line ("Receiving command: $cmd with args: $args\n");
        my $user = undef;
        if (exists $access_cfg -> {$addr} &&
            exists $access_cfg -> {$addr}{$cmd}){
            syswrite ($cmd_socket, "STAT *** OK COMMAND ($cmd)\n",
                     $SOCK_BUF);
            if (exists $access_cfg -> {"ALL_HOSTS"} -> {"$cmd"."#USER#"}){
                $user = $access_cfg -> {"ALL_HOSTS"} -> {"$cmd"."#USER#"};
            }
            exec_cmd($access_cfg -> {$addr}{$cmd}, $args, $user);
        } elsif (exists $access_cfg -> {"ALL_HOSTS"} &&
                 exists $access_cfg -> {"ALL_HOSTS"}{$cmd}){
            syswrite ($cmd_socket, "STAT *** OK COMMAND ($cmd)\n", 
                      $SOCK_BUF);
            if (exists $access_cfg -> {"ALL_HOSTS"} -> {"$cmd"."#USER#"}){
                $user = $access_cfg -> {"ALL_HOSTS"} -> {"$cmd"."#USER#"};
            }
            exec_cmd($access_cfg -> {"ALL_HOSTS"}{$cmd}, $args, $user);
        } else {
            print $cmd_socket "STAT *** BAD COMMAND (no access)\n";
            log_line ("STAT *** BAD COMMAND (no access) $command_line\n");
        }
        close ($cmd_socket);
        log_line ("Closing socket (PID $$)\n");
        exit 0;
    }
    close ($cmd_socket);
}

sub exec_cmd{
    my ($cmd, $args, $user) = @_;
    my $command = "$cmd $args";
    if (defined $user){
       $command = "su -c \"$command\"";
    }
    log_line ("Execute command $command (PID $$)\n");
       
    open (command_output, "$command|");
    while (<command_output>){
        syswrite ($cmd_socket, $_, $SOCK_BUF);
    }
    log_line ("Programm ended (PID $$)\n");
}

###################################
# read_cfg
# 
# Reads a access file and returns a configuration hash
#
# Parameters:
# 
# $cfg_file: Path to dim_STAT access file
#

sub read_cfg
{
    my $cfg_file = shift;
    my $cfg_hash = {};
    open (IN, $cfg_file) || die "Cannot open access file $cfg_file\n$!\n";
    my @current_access_addr = ();
    my $current_user = undef;
    my $cmd_part = 0;
    while (<IN>){
        next if /^#/;
        $_ =~ tr /\t/ /s;
        $_ =~ tr / //s;
        my $current_line = $_;
        if ($current_line =~/^access (.*)/){
            if ($cmd_part){
               @current_access_addr = ();
               $cmd_part = 0;
            }                   
            push (@current_access_addr, $1);
        }
        if ($current_line =~/^command ([^ #]+) (.*)/){
            $cmd_part = 1;
            my $user = undef;
            my ($command_name, $command) = ($1, $2);
            if ($command_name =~ /(.*):(.*)/){
                $user = $1;
                $command_name = $2;
            }
            if ($#current_access_addr == -1){
                if (-x $command){
                    $cfg_hash -> {'ALL_HOSTS'} {$command_name} = $command;
                    if ($user){
                        $cfg_hash -> {'ALL_HOSTS'} {$command_name."#USER#"} = $user 
                    }                                                 
                }
                else{
                warn "File $command is not executable or does not exists"
                }
            }
            else{
                foreach my $addr (@current_access_addr){
                    if (-x $command){
                        $cfg_hash -> {$addr}{$command_name} = $command;
                        if ($user){
                            $cfg_hash -> {$addr} {$command_name."#USER#"} = $user
                        }                                          
                    }
                    else {
                        warn "File $command is not executable or does not exists";
                    }    
               }
            }
        }
    }
    return $cfg_hash;
}
sub log_line 
{
    my $str = shift;
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
    $year += 1900; $mon++;
    printf("-- %04d-%02d-%02d %02d:%02d:%02d %s", $year, $mon, $mday,
                          $hour, $min, $sec, $str);
}
sub log_verbose
{
    print "-";
    log_line(shift);
}

sub usage 
{
    print "stat_agent.pl - dim_STAT monitoring agent\n";
    print "Version: $VERSION\n";
    print "Synopsis:\n";
    print "stat_agent.pl -f access_file [-p port] [-l logfile] [-d] [-v]\n";
    print "--port, -p\tServerport\n";
    print "--file, -f\tAccessfile\n";
    print "--daemon, -d\tRunning in servermode\n";
    print "--log, -l\tSpecify log file\n";
    print "--verbose, -v\tVerbosemode\n";
    exit 0;
}
