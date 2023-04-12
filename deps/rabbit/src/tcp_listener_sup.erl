%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(tcp_listener_sup).

%% Supervises TCP listeners. There is a separate supervisor for every
%% protocol. In case of AMQP 0-9-1, it resides under rabbit_sup. Plugins
%% that provide protocol support (e.g. STOMP) have an instance of this supervisor in their
%% app supervision tree.
%%
%% See also rabbit_networking and tcp_listener.

-behaviour(supervisor).

-export([start_link/11]).
-export([init/1]).

-type mfargs() :: {atom(), atom(), [any()]}.
-type endpoint() :: rabbit_net:endpoint().

-spec start_link
        (endpoint(), module(), [gen_tcp:listen_option()],
         module(), any(), mfargs(), mfargs(), integer(), integer(), 'worker' | 'supervisor', string()) ->
                           rabbit_types:ok_pid_or_error().

start_link(EndPoint, Transport, SocketOpts, ProtoSup, ProtoOpts, OnStartup, OnShutdown,
           ConcurrentAcceptorCount, ConcurrentConnsSups, ConnectionType, Label) ->
    supervisor:start_link(
      ?MODULE, {EndPoint, Transport, SocketOpts, ProtoSup, ProtoOpts, OnStartup, OnShutdown,
                ConcurrentAcceptorCount, ConcurrentConnsSups, ConnectionType, Label}).

init({EndPoint, Transport, SocketOpts, ProtoSup, ProtoOpts, OnStartup, OnShutdown,
      ConcurrentAcceptorCount, ConcurrentConnsSups, ConnectionType, Label}) ->
    {ok, AckTimeout} = application:get_env(rabbit, ssl_handshake_timeout),
    MaxConnections = max_conn(rabbit_misc:get_env(rabbit, ranch_connection_max, infinity),
                              ConcurrentConnsSups),
    RanchListenerOpts = #{
      num_acceptors => ConcurrentAcceptorCount,
      max_connections => MaxConnections,
      handshake_timeout => AckTimeout,
      connection_type => ConnectionType,
      socket_opts => socket_opts(EndPoint, SocketOpts),
      num_conns_sups => ConcurrentConnsSups
     },
    Flags = {one_for_all, 10, 10},
    OurChildSpecStart = {tcp_listener, start_link, [EndPoint, OnStartup, OnShutdown, Label]},
    OurChildSpec = {tcp_listener, OurChildSpecStart, transient, 16#ffffffff, worker, [tcp_listener]},
    RanchChildSpec = ranch:child_spec(rabbit_networking:ranch_ref(EndPoint),
        Transport, RanchListenerOpts,
        ProtoSup, ProtoOpts),
    {ok, {Flags, [RanchChildSpec, OurChildSpec]}}.

-spec socket_opts(endpoint(), list()) -> list().
socket_opts({{local, File}, _, local}, SocketOpts) ->
  Local = {local, iolist_to_binary(File)},  % ranch code seems to deal only with binaries even if its spec is inet:local_address ?
  [{ip, Local}, {port, 0} | SocketOpts];
socket_opts({IPAddress, Port, Family}, SocketOpts) ->
  [{ip, IPAddress}, {port, Port}, Family | SocketOpts].

max_conn(infinity, _) ->
    infinity;
max_conn(Max, Sups) ->
  %% connection_max in Ranch is per connection supervisor
  Max div Sups.
