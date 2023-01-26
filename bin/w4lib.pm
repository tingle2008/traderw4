package w4Range;
use warnings 'all';
use strict;

BEGIN
{
    my $rootdir;

    require File::Basename;
    require File::Spec;

    my $name=File::Spec->rel2abs($0);
    $rootdir=File::Basename::dirname($name);
    $rootdir=~s/\/?bin$//;

    #require  Seco::AwesomeRange;
    require "$rootdir/bin/w4Range.pm";
}
sub expand_range
{
    Seco::AwesomeRange::want_caching(0);
    Seco::AwesomeRange::expand_range(@_);
    #return Seco::Range::expand_range(@_);
     
}
sub compress_range
{
    Seco::AwesomeRange::want_caching(0);
    Seco::AwesomeRange::compress_range(@_);
    #Seco::Range::compress_range(@_);
}

package my_watcher;
use warnings 'all';
use strict;
use threads;
use Thread::Queue;
use POSIX;
use File::Basename;
use File::Spec;
use YAML::Syck;
use Fatal qw(mkdir);

sub new
{
    my $class=shift;
    my $name=shift;
    my $rootdir=shift;
    my $vardir=shift;
    my $watcher_cmds=shift;
    my $handler_cmds=shift;
    my %params=@_;
    my $obj={};
    die if ! defined $name;
    die if ! defined $rootdir;
    die if ! defined $vardir;
    die if ! defined $watcher_cmds;
    die if ! defined $handler_cmds;
    die if defined $params{name};
    $obj->{name}=$name;
    $obj->{config}= defined $params{config}? $params{config}: $name;
    $obj->{rootdir}=$rootdir;
    $obj->{statedir}="$vardir/state";
    $obj->{logdir}="$vardir/log";
    map {mkdir $obj->{$_} if ! -d $obj->{$_}} qw (statedir logdir);

    $obj->{cfg}=YAML::Syck::LoadFile("$rootdir/conf/watcher/default.yaml");

    die if defined $obj->{cfg}{HOSTS};
    $obj->{cfg}{HOSTS}=[];

    my $self=bless($obj,$class);
    $self->configure($watcher_cmds,$handler_cmds,%params);
    return $self;
}

sub set_conf
{
    my $self=shift;

    my %conf=@_;

    my @config_changed;
    for my $key (keys %conf)
    {
        die "unknown key $key" if! defined $self->{cfg}{$key};
        die "wrong type for $key" if ref $self->{cfg}{$key} ne ref $conf{$key};
        if(ref $conf{$key} eq 'ARRAY')
        {
      
            die "wrong number of elements in array $key" if @{$conf{$key}} ne @{$self->{cfg}{$key}};
            my $ovr=0;
            map {$ovr=1 if $self->{cfg}{$key}[$_] ne $conf{$key}[$_]} 0.. $#{$conf{$key}};
            next if ! $ovr;
            push @config_changed,$key;
            @{$self->{cfg}{$key}}=@{$conf{$key}};
        }
        elsif(ref $conf{$key} eq '')
        {
            next if $self->{cfg}{$key} eq $conf{$key};
            push @config_changed,$key;
            $self->{cfg}{$key}=$conf{$key};
        }
        else
        {
            die "unknown key $key";
        }
    }
    return \@config_changed;
}
sub configure
{
    my $self=shift;
    my $watcher_cmds=shift;
    my $handler_cmds=shift;
    my %ovr=@_;

    my $cfg=YAML::Syck::LoadFile("$self->{rootdir}/conf/watcher/default.yaml");

    my $cfg1=YAML::Syck::LoadFile("$self->{rootdir}/conf/watcher/".$self->{config}.".yaml");
    @$cfg{keys %$cfg1}=values %$cfg1;
    
    $cfg->{QUERY_COMMAND}=$self->{config} if $cfg->{QUERY_COMMAND} eq '' ;

    die if exists $cfg->{config};
    delete $ovr{config};
   
    @$cfg{keys %ovr}=values %ovr;

    my $params_changed=$self->set_conf(%$cfg);

    die if ! defined $cfg->{QUERY_RANGE};
    if(0) #hosts are resolved for every run
    {
        $self->{HOSTS}=[w4Range::expand_range($cfg->{QUERY_RANGE})];
        die if @{$self->{HOSTS}} && (!defined $self->{HOSTS}[0] || $self->{HOSTS}[0] eq '');
    }

#    $self->{cfg}{QUERY_COMMAND}=$self->{config} if (!defined $self->{cfg}{QUERY_COMMAND}) || ($self->{cfg}{QUERY_COMMAND} eq '') ;
    die "undefined QUERY_COMMAND $self->{cfg}{QUERY_COMMAND}" if ! defined $watcher_cmds->{$self->{cfg}{QUERY_COMMAND}};

    die "undefined RESULT_HANDLER $self->{cfg}{RESULT_HANDLER}" if $self->{cfg}{RESULT_HANDLER} ne '' && ! defined $handler_cmds->{$self->{cfg}{RESULT_HANDLER}};

    return $params_changed;
}
sub get_frequency
{
    my $self=shift;
    die if ! defined $self->{cfg}{FREQUENCY};
    return $self->{cfg}{FREQUENCY};
}
sub get_handler
{
    my $self=shift;
    die if ! defined $self->{cfg}{RESULT_HANDLER};
    die if ! defined $self->{cfg}{RESULT_HANDLER_PARAMS};
    return ($self->{cfg}{RESULT_HANDLER},$self->{cfg}{RESULT_HANDLER_PARAMS});
}
sub run
{
    my ($self,$threads, $result_q,$excludes)=@_;

    my @free_threads=(0..($self->{cfg}{MAX_THREADS}< @$threads? $self->{cfg}{MAX_THREADS}: @$threads)-1);

    my %hosts_results;
    my $threads_scheduled=0;
    my $hosts_scheduled=0;
    my $error='';

    my $state_fname="$self->{statedir}/$self->{name}.yaml";
    my $log_fname="$self->{logdir}/$self->{name}.yaml";

    my $old_state=eval { YAML::Syck::LoadFile($state_fname)};
    $old_state={} if ! defined $old_state;

    my $state={};
    my @hosts;
    if(1) #resolve hosts every tun
    {
        $self->{HOSTS}=[w4Range::expand_range($self->{cfg}{QUERY_RANGE})];
        die if @{$self->{HOSTS}} && (!defined $self->{HOSTS}[0] || $self->{HOSTS}[0] eq '');
    }
    for(@{$self->{HOSTS}})
    {
        push @hosts,$_ if ! defined $excludes->{$_};
        $state->{$_}=defined $old_state->{$_}? $old_state->{$_}: {status=>'OK', status_time=>time,msg=>''};
    }
    undef $old_state;

    while($threads_scheduled || $hosts_scheduled<@hosts)
    {
        while( my $yaml_r=$result_q->dequeue_nb)
        {
            my $result=YAML::Syck::Load($yaml_r);
            my $thread=$result->{thread};
#            print "TID $thread: returned\n";

            if($error eq '' && ref $result->{result} eq 'HASH')
            {
                @hosts_results{keys %{$result->{result}}}=values %{$result->{result}};
            }
            unshift @free_threads,$thread;
            $threads_scheduled--;
        }
        if(@free_threads && $hosts_scheduled<@hosts)
        {
            my $last_host=$hosts_scheduled+$self->{cfg}{MAX_RANGE}-1;
            $last_host=@hosts-1 if $last_host>@hosts-1;

            my $thread=shift @free_threads;
            $threads->[$thread]{hosts}=[@hosts[$hosts_scheduled..$last_host]];
#            printf "TID $thread scheduling %s\n",compress_range(@{$threads->[$thread]{hosts}});
            $threads->[$thread]{queue}->enqueue($self->{cfg}{QUERY_COMMAND});
            $threads->[$thread]{queue}->enqueue($self->{cfg}{QUERY_COMMAND_TIMEOUT});
            $threads->[$thread]{queue}->enqueue($self->{cfg}{QUERY_COMMAND_PARAMS});
            $threads->[$thread]{queue}->enqueue(join ' ',@{$threads->[$thread]{hosts}});
            $threads_scheduled++;
            $hosts_scheduled=$last_host+1;
        }
        elsif($threads_scheduled)
        {
            sleep 1;
        }
    }
    my @events;
    #aggregate results
    my %watcher_results=(host=>{},status_host=>{},status_msg_host=>{});

    my %status=map{($_,1)} qw(OK WARNING ERROR UNKNOWN);
    for my $host(@hosts)
    {
        my $status='UNKNOWN';
        my $msg='';
        if (! defined $hosts_results{$host})
        {
           $msg="no result";
        }
        elsif(ref $hosts_results{$host} ne 'ARRAY' || @{$hosts_results{$host}}!=2 || !defined $status{$hosts_results{$host}[0]})
        {
            $msg='invalid response';
        }
        else
        {
            $status=$hosts_results{$host}[0];
            $msg=$hosts_results{$host}[1];
        }
        
        if(! defined $state->{$host}|| $state->{$host}{status} ne $status)
        {
            $state->{$host}{status_time}=time;
            $state->{$host}{status}=$status;
            push @events,{host=>$host, msg=>$msg,status=>$status, status_time=>$state->{$host}{status_time}};
        }

        my $r={msg=>$msg, status=>$status, status_time=>$state->{$host}{status_time}};

        $watcher_results{host}{$host}=$r;
        $watcher_results{status_host}{$status}{$host}=$r;
        $watcher_results{status_msg_host}{$status}{$msg}{$host}=$r;

        $state->{$host}{msg}=$msg;
    }
    if(1)
    {
        unlink "$state_fname.new" if -f "$state_fname.new";
        YAML::Syck::DumpFile("$state_fname.new",$state);
        rename $state_fname, "$state_fname.old" if -f $state_fname;
        unlink $state_fname if -f $state_fname;
        rename "$state_fname.new", $state_fname;
        unlink "$state_fname.old" if -f "$state_fname.old";

        my $log='';
        for(@events)
        {
            local $YAML::Syck::Headless=1;
            $log.=YAML::Syck::Dump($_)."---\n";
        }
        if($log ne '')
        {
            open F,">>$log_fname" or die "open $log_fname: $!";
            print F $log;
            close F;
        }
    }
    return \%watcher_results;
}
1;

package w4;
use strict;
use threads;
use Thread::Queue;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use YAML::Syck;
#use my_watcher;

sub new
{
    my $class=shift;
    my $log=shift;
    my $config_name=shift;
    my %params=@_;
    my $obj={};

    my $rootdir;
    if (defined $params{rootdir})
    {
        $rootdir=$params{rootdir};
    }
    else
    {
        require File::Basename;
        require File::Spec;

        my $name=File::Spec->rel2abs($0);
        $rootdir=File::Basename::dirname($name);
        $rootdir=~s/\/?bin$//;
    }
    die if ! defined $rootdir or $rootdir!~m{/};


    die if ! defined $config_name;
    my $config_file="$rootdir/conf/$config_name.yaml";
    die "config file $config_file is not found" if ! -f $config_file;

    my $vardir=defined $params{vardir}? $params{vardir}: "$rootdir/var/$config_name";
    mkdir $vardir if ! -d $vardir;
    die if ! -d $vardir;

    die if ! defined $log;
    die if ref $log ne 'CODE';

    die if defined $params{name};
    $obj->{rootdir}=$rootdir;
    $obj->{vardir}=$vardir;
    $obj->{config_file}=$config_file;
    $obj->{config_name}=$config_name;
    $obj->{log}=$log;
    $obj->{watchers}={};
    $obj->{rt}={};                     #runtime data
    $obj->{handler_state}={};
    $obj->{exclude}{global_scan_time}=0;
    $obj->{exclude}{scan_time}={};

    $obj->{threads}=[];
    $obj->{result_q}=Thread::Queue->new;
    $obj->{code}={};
    $obj->{code_md5}={};

    $obj->{numthreads}= defined $params{numthreads}? $params{numthreads}: 2;

    my $self=bless($obj,$class);
    $self->configure();
    return $self;
}

sub load_code
{
    my ($self)=@_;
    
    #load new code
    my %code_found;
    for my $codetype ("watcher","handler")
    {
        $self->{code}{$codetype}={};
        my $path="$self->{rootdir}/lib/$codetype";
        next if ! opendir DIR,$path;
        while (my $cmd=readdir DIR)
        {
            next if $cmd=~/^\./;
            next if ! -f "$path/$cmd";
            next if ! open F,"$path/$cmd";
            local $/;
            my $file=<F>;
            close F;
            my $md5=md5($file);

            $code_found{$md5}=1;
            if(!defined $self->{code_md5}{$md5})
            {
                no warnings 'redefine';
                no warnings;# 'redefine';
                my $c=eval $file;
                if($@)
                {
                    $self->{code_md5}{$md5}{error}="$@";
                }
                elsif(ref $c ne 'CODE')
                {
                    $self->{code_md5}{$md5}{error}='not a code reference';
                }
                else
                {
                    $self->{code_md5}{$md5}{code}=$c;
                    $self->{log}('INFO','',"loaded code $codetype/$cmd",'');
                }
            }
            if(defined $self->{code_md5}{$md5}{code})
            {
                $self->{code}{$codetype}{$cmd}=$self->{code_md5}{$md5}{code};
            }
            else
            {
                $self->{log}('ERROR','',"couldn't load code $path/$cmd", $self->{code_md5}{$md5}{error});
            }
        }
        closedir DIR;
    }

    for my $md5 (keys %{$self->{code_md5}})
    {
        next if defined $code_found{$md5};
        delete $self->{code_md5}{$md5};
    }
}

sub configure
{
    my ($self)=@_;
    my $config=YAML::Syck::LoadFile($self->{config_file});

    $self->{log}('INFO','',"configure watchers",'');

    # forse recheck of excludes
    $self->{exclude}{global_scan_time}=0;
    $self->{exclude}{scan_time}={};

    #stop the threads
    for my $i(0..@{$self->{threads}}-1)
    {
        $self->{threads}[$i]{queue}->enqueue(undef);
        $self->{threads}[$i]{thread}->join();
    }
    @{$self->{threads}}=();

    $self->load_code();
    my %watcher_cmds=map {($_=>1)} keys %{$self->{code}{watcher}};
    my %handler_cmds=map {($_=>1)} keys %{$self->{code}{handler}};

    #reconfigure /delete existing watchers
    for my $watcher_name (sort keys %{$self->{watchers}})
    {
        if(!defined $config->{$watcher_name})
        {
            delete $self->{watchers}{$watcher_name};
            delete $self->{rt}{$watcher_name};
            delete $self->{handler_state}{$watcher_name};
            $self->{log}('INFO',$watcher_name,"deleted",'');
        }
        else
        {
            my $params_changed=eval {$self->{watchers}{$watcher_name}->configure(\%watcher_cmds,\%handler_cmds,%{$config->{$watcher_name}})};
            if($@)
            {
                $self->{log}('CRITICAL',$watcher_name,"Failed to configure",$@);
                delete $self->{watchers}{$watcher_name};
                next;
            }
            $self->{log}('INFO',$watcher_name,"changed parameters",join("\n",@$params_changed)) if @$params_changed;
        }
    }
    #create new watchers
    for my $watcher_name (sort keys %$config)
    {
        next if defined $self->{watchers}{$watcher_name};
        eval {$self->{watchers}{$watcher_name}=new my_watcher($watcher_name, $self->{rootdir},$self->{vardir}, \%watcher_cmds,\%handler_cmds,%{$config->{$watcher_name}})};
        if($@)
        {
            $self->{log}('CRITICAL',$watcher_name,"Failed to create",$@);
            delete $self->{watchers}{$watcher_name};
            next;
        }
        $self->{rt}{$watcher_name}{start_time}=time;
        $self->{handler_state}{$watcher_name}=undef;
        $self->{log}('INFO',$watcher_name,"Created",'');
    }

    #create thread pool & msg queues
    die if ! defined $self->{numthreads};
    for my $i(0..$self->{numthreads}-1)
    {
        my $q=Thread::Queue->new;
        my $t=threads->new(\&worker,$i,$q,$self->{result_q},$self->{code}{watcher});
        $self->{threads}[$i]={thread=>$t,queue=>$q};
   }
}

#returns a hash of hosts that should be excluded from watcher
sub get_excludes
{
    my ($self,$watcher)=@_;

    my $time=time;
    $self->{exclude}{data}{$watcher}={} if ! defined $self->{exclude}{data}{$watcher};
    $self->{exclude}{scan_time}{$watcher}=0 if ! defined $self->{exclude}{scan_time}{$watcher};
    $self->{exclude}{global_data}   ={} if ! defined $self->{exclude}{global_data};
    my @exclude_conf=(
    {
        exclude_dir=>       "$self->{vardir}/exclude/watcher/$watcher",
        data=>              \$self->{exclude}{data}{$watcher},
        last_scan_time_ref=>\$self->{exclude}{scan_time}{$watcher}
    },
    {
        exclude_dir=>"$self->{vardir}/exclude/global",
        data=>\$self->{exclude}{global_data},
        last_scan_time_ref=>\$self->{exclude}{global_scan_time}
    });
    for my $ctx (@exclude_conf)
    {
        next if $time-${$ctx->{last_scan_time_ref}}<60; #don't scan frequently (no more that 1 time/min)
        ${$ctx->{last_scan_time_ref}}=$time;
        opendir DIR,$ctx->{exclude_dir} or next;

        my $ex_data={};
        while (my $name=readdir DIR)
        {
            next if $name=~/^\./;
            my $ex_file="$ctx->{exclude_dir}/$name";
            next if ! -f $ex_file;
            my $mtime=(stat _)[9];
            next if $mtime>$time;
            next if ! open F,$ex_file;
            local $/;
            my $f=<F>;
            close F;
            my ($exclude_time)= $f=~/^(\d+)\n?$/;
            $exclude_time||=300;
            if($mtime+$exclude_time<$time)
            {
                $self->{log}('INFO','',"deleting expired exclude $name",'');
                unlink $ex_file;
                next;
            }
            my @nodes=w4Range::expand_range($name);
            if(!@nodes || $nodes[0] eq '')
            {
                $self->{log}('ERROR','',"No hosts from w4Range::expand_range for $name",'');
                next;
            }
            $ex_data->{$name}={time=>$mtime+$exclude_time,nodes=>\@nodes};
            
            my $new_nodes=join(' ',@nodes);
            my $old_nodes=join(' ',@{${$ctx->{data}}->{$name}{nodes}}) if defined ${$ctx->{data}}->{$name};
            if(!defined $old_nodes || $old_nodes ne $new_nodes || $ex_data->{$name}{time} ne ${$ctx->{data}}->{$name}{time})
            {
                $self->{log}('INFO','',sprintf("excluding %s for %d seconds",$name, $mtime+$exclude_time-$time),$new_nodes);
            }
        }
        ${$ctx->{data}}=$ex_data;
        closedir DIR;
    }
    my %hosts;
    for my $ctx (@exclude_conf)
    {
        for my $name (keys %{${$ctx->{data}}})
        {
            map {$hosts{$_}=1} @{${$ctx->{data}}->{$name}{nodes}} if ${$ctx->{data}}->{$name}{time}>=$time;
        }
    }
    return \%hosts;
}

sub run
{
    my $self=shift;
    my $time=time;
    my $watcher_to_run;
    my $next_watcher_time;
    my $overdue;
    for my $watcher (sort keys %{$self->{watchers}})
    {
        my $start_time=$self->{rt}{$watcher}{start_time};
        my $freq=$self->{watchers}{$watcher}->get_frequency();
        my $next_run;
        if(!defined $self->{rt}{$watcher}{run_start} || !$freq)
        {
            $next_run=$start_time;
        }
        else
        {
            $next_run=$self->{rt}{$watcher}{run_start} - ($self->{rt}{$watcher}{run_start} -$start_time)% $freq+$freq;
        }
        next if $next_run>$time;

        if (! defined $next_watcher_time || $next_watcher_time>$next_run)
        {
            $next_watcher_time=$next_run;
            $watcher_to_run=$watcher;
            undef $overdue;
            $overdue=sprintf("scheduler is overdue by %d seconds",$time-$next_run) if $freq && $next_run+$freq<$time;
        }
    }
    if(defined $watcher_to_run)
    {
        my $state;
        $self->{log}('WARNING',$watcher_to_run,$overdue,'') if defined $overdue;
        $self->{rt}{$watcher_to_run}{run_start}=time;
        $state=$self->run_watcher($watcher_to_run);
        $self->{rt}{$watcher_to_run}{run_finish}=time;
        return 1;
    }
    return 0;
}

sub run_watcher
{
    my ($self,$watcher)=@_;

    # run watcher
    $self->{log}('DEBUG',"$watcher","running watcher",'');
    my $results=$self->{watchers}{$watcher}->run($self->{threads}, $self->{result_q},$self->get_excludes($watcher));

    #process aggregated results
    my $watcher_status;
    my @summary;
    my $log_msg='';
    for my $status (qw(ERROR UNKNOWN WARNING OK))
    {
        my $nh=scalar(keys %{$results->{status_host}{$status}});
        if($nh)
        {
            $watcher_status||=$status;
            push @summary,"$nh $status";
            $log_msg.="$status: ". w4Range::compress_range(keys %{$results->{status_host}{$status}})."\n";
            next if $status eq 'OK';
            for my $msg (sort keys %{$results->{status_msg_host}{$status}})
            {
                $log_msg.="\t$msg: ". w4Range::compress_range(keys %{$results->{status_msg_host}{$status}{$msg}}) . "\n";
            }
        }
    }
    if(!defined $watcher_status)
    {
        $watcher_status='OK';
        push @summary, 'No hosts to query';
    }
    $self->{log}('DEBUG',$watcher,"result: $watcher_status. ".join(', ',@summary),$log_msg);

    # call handler
    my ($handler,$handler_params)=$self->{watchers}{$watcher}->get_handler();
    if($handler ne '')
    {
        eval {$self->{code}{handler}{$handler}(\$self->{handler_state}{$watcher},$handler_params,$results,$watcher,$self->{config_name})};
        if($@)
        {
            $self->{log}("ERROR",$watcher,"handler $handler failed",$@);
        }
    }
}
sub worker
{
    my ($id,$in_q,$out_q,$code)=@_;
    my %code;
    my $result;
    while (my $cmd=$in_q->dequeue)
    {
        my $timeout=$in_q->dequeue;
        my $params=$in_q->dequeue;
        my @hosts=split / /,$in_q->dequeue;

        $result={};

        eval
        {
            local $SIG{ALRM} = sub {die "QUERY_COMMAND_TIMEOUT\n"};
            alarm($timeout) if $timeout;
            &{$code->{$cmd}}($result,$params,@hosts);
            alarm(0) if $timeout;
        };
        if($@)
        {
            my $err=$@;
            chomp $err;
            for(@hosts)
            {
                $result->{$_}=['UNKNOWN',$err] if ! defined  $result->{$_};
            }
        }
        $out_q->enqueue(YAML::Syck::Dump{thread=>$id,command=>$cmd,result=>$result});
    }
}
1;
