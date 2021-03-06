# Copyright (c) 2016, Mitchell Cooper
#
# Created on Mitchells-Mac-mini.local
# Sat Aug  9 23:22:50 EDT 2014
# Registration.pm
#
# @name:            'TS6::Registration'
# @package:         'M::TS6::Registration'
# @description:     'registration commands for TS6 protocol'
#
# @depends.bases+   'RegistrationCommands'
# @depends.modules+ 'TS6::Utils', 'TS6::Base'
#
# @author.name:     'Mitchell Cooper'
# @author.website:  'https://github.com/cooper'
#
package M::TS6::Registration;

use warnings;
use strict;
use 5.010;

use utils qw(conf irc_match notice ref_to_list irc_lc broadcast);
use M::TS6::Utils qw(
    ts6_id sid_from_ts6 user_from_ts6
    server_from_ts6 ts6_uid ts6_sid
);

our ($api, $mod, $pool, $conf, $me);

my ($TS_CURRENT, $TS_MIN) =(
    $M::TS6::Base::TS_CURRENT,
    $M::TS6::Base::TS_MIN
);

our %ts6_capabilities = (
    ENCAP       => { required => 1 },   # enhanced command routing
    QS          => { required => 1 },   # quit storm
    EX          => { required => 1 },   # ban exceptions
    IE          => { required => 1 },   # invite exceptions
    EUID        => { required => 0 },   # extended user introduction
    TB          => { required => 0 },   # topic burst
    EOB         => { required => 0 },   # end of burst token
    SERVICES    => { required => 0 },   # umode +S and cmode +r
    SAVE        => { required => 0 },   # resolve nick collisions without kills
    SAVETS_100  => { required => 0 },   # ratbox: silences warnings about SAVE
    RSFNC       => { required => 0 },   # forcenick extension
    CLUSTER     => { required => 0 },   # KLINE, XLINE, RESV, LOCOPS
    EOPMOD      => { required => 0 },   # extended topic burst (ETB), +z stuff
    CHW         => { required => 0 },   # messages to @#channel
    KNOCK       => { required => 0 },   # request for channel invitation
    MLOCK       => { required => 0 },   # mode lock
);

our %registration_commands = (
    CAPAB => {
        code   => \&rcmd_capab,
        params => 1,
        proto  => 'ts6'
    },
    PASS => {
        code   => \&rcmd_pass,
        params => 4,
        proto  => 'ts6'
    },
    SERVER => {
        code   => \&rcmd_server,
        params => 3,
        proto  => 'ts6'
    },
    PING => {
        code   => \&rcmd_ping,
        params => 1,
        proto  => 'ts6'
    },
    SVINFO => {
        code   => \&rcmd_svinfo,
        params => 3,
        proto  => 'ts6'
    }
);

sub init {
    $pool->on('connection.server_ready' =>
        \&server_ready,
        'ts6.server_ready'
    );
    $pool->on('connection.ready_done' =>
        \&connection_ready,
        'ts6.ready_done'
    );
    $pool->on('server.initially_propagated' =>
        \&server_propagated,
        'ts6.start.burst'
    );
    return 1;
}

# CAPAB
#
# source:       unregistered server
# propagation:  none
# parameters:   space separated capability list
#
# ts6-protocol.txt:209
#
sub rcmd_capab {
    my ($conn, $event, @flags) = @_;
    $conn->add_cap(map { split /\s+/ } @flags);
}

# PASS
#
# source:       unregistered server
# parameters:   password, 'TS', TS version, SID
#
# ts6-protocol.txt:623
#
sub rcmd_pass {
    my ($conn, $event, $pass, undef, $ts_version, $sid) = @_;
    $conn->{proto} = $ts_version;

    # not supported.
    if ($ts_version != $TS_CURRENT) {
        notice(server_protocol_error =>
            'Unregistered server from '.$conn->{host},
            "will not be linked due to an incompatible TS version ($ts_version)"
        );
        $conn->done("Incompatible TS version ($ts_version)");
        return;
    }

    # temporarily store password and SID.
    @$conn{'ts6_sid', 'pass'} = ($sid, $pass);

    $conn->reg_continue('id1');
    return 1;
}

# SERVER
#
# 1.
# source:       unregistered server
# parameters:   server name, hopcount, server description
#
# 2.
# source:       server
# propagation:  broadcast
# parameters:   server name, hopcount, server description
#
# ts6-protocol.txt:783
#
sub rcmd_server {
    my ($conn, $event, $name, undef, $desc) = @_;
    @$conn{ qw(name desc ircd) } = ($name, $desc, -1);
    my $s_conf = ['connect', $name];

    # hidden?
    my $sub = \substr($conn->{desc}, 0, 4);
    if (length $sub && $$sub eq '(H) ') {
        $$sub = '';
        $conn->{hidden} = 1;
    }

    # haven't gotten PASS yet.
    if (!defined $conn->{ts6_sid}) {
        $conn->done('Invalid credentials');
        return;
    }

    $conn->{sid} = sid_from_ts6($conn->{ts6_sid});

    # if this was by our request (as in an autoconnect or /connect or something)
    # don't accept any server except the one we asked for.
    if (length $conn->{want} &&
    irc_lc($conn->{want}) ne irc_lc($conn->{name})) {
        $conn->done('Unexpected server');
        return;
    }

    # find a matching server.
    if (defined(my $addrs = conf($s_conf, 'address'))) {
        $addrs = [$addrs] if !ref $addrs;
        if (!irc_match($conn->{ip}, @$addrs)) {
            $conn->done('Invalid credentials');
            notice(connection_invalid => $conn->{ip}, 'IP does not match configuration');
            return;
        }
    }

    # no such server.
    else {
        $conn->done('Invalid credentials');
        notice(connection_invalid => $conn->{ip}, 'No block for this server');
        return;
    }

    # check for valid password.
    my $password = utils::crypt(
        $conn->{pass},
        conf($s_conf, 'encryption')
    );
    if ($password ne conf($s_conf, 'receive_password')) {
        $conn->done('Invalid credentials');
        notice(connection_invalid => $conn->{ip}, 'Received invalid password');
        return;
    }

    # made it.
    $conn->fire('looks_like_server');
    $conn->{ircd_name} = conf($s_conf, 'ircd') // 'charybdis';
    $conn->{link_type} = 'ts6';
    $conn->reg_continue('id2');

    return 1;

}

# server info
sub rcmd_svinfo {
    my ($conn, $event, $current, $min, undef, $their_time) = @_;
    my $server = $conn->server or return;

    # check for errors
    if (my $err = $conn->verify) {
        $conn->done($err);
        return;
    }

    # bad TS version
    if ($TS_CURRENT < $min || $current < $TS_MIN) {
        my $ver_str = "($current,$min)";
        notice(server_protocol_error =>
            $server->notice_info,
            'will not be linked due to an incompatible TS version '.$ver_str
        );
        $conn->done("Incompatible TS version $ver_str");
        return;
    }

    # check if the delta is enormous.
    server::protocol::check_ts_delta($conn, time, $their_time)
        or return;

    $server->{proto} = $current;
    return 1;
}

# the first ping here indicates end of burst.
sub rcmd_ping {
    my ($conn, $event) = @_;
    my $server = $conn->server or return;
    $server->{is_burst} or return;
    $server->end_burst();
    broadcast(endburst => $server, time);
}

sub server_ready {
    my $server = shift->server or return;
    return unless $server->{link_type} eq 'ts6';

    # apply modes.
    server::protocol::ircd_register_modes($server);

    # add user lookup functions.
    $server->set_functions(
        uid_to_user     => \&user_from_ts6,
        user_to_uid     => \&ts6_uid,
        sid_to_server   => \&server_from_ts6,
        server_to_sid   => \&ts6_sid
    );

}

# connection is ready event.
sub connection_ready {
    my $conn = shift;
    my $server = $conn->server or return;
    return unless $server->{link_type} eq 'ts6';

    # search for required CAPABs.
    foreach my $need (M::TS6::Base::get_required_caps()) {
        next if $server->has_cap($need);
        $conn->done("Missing required CAPABs ($need)");
        return;
    }

    # if I haven't already, time to send my own credentials.
    M::TS6::Base::initiate_ts6_link($conn)
        unless $conn->{sent_creds};

    # unless I initiated this, I have to send my burst first.
    # I am to send it now, immediately after sending my registration,
    # even before the initiator has verified my credentials.
    $server->send_burst if !$server->{i_sent_burst};

}

# after sending out SID, start the burst
sub server_propagated {
    my $server = shift;
    return if $server->{link_type} ne 'ts6';
    return if $server->{is_burst} || $server->{sent_burst};

    # at this point, we will say that the server is starting its burst.
    # however, it still may deny our own credentials.
    $server->start_burst();

    # tell other servers
    broadcast(burst => $server, time);
}

$mod
