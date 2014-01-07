%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Connection Management Module.

-module(nksip_transport_conn).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_transport/5, start_connection/5, get_connected/4]).
-export([ranch_start_link/6, start_link/4]).

-include("nksip.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Start a new listening transport.
-spec start_transport(nksip:sipapp_id(), nksip:protocol(), inet:ip_address(), 
                      inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_transport(AppId, Proto, Ip, Port, Opts) ->
    Listening = [
        {LIp, LPort} || 
            {#transport{listen_ip=LIp, listen_port=LPort}, _Pid} 
            <- nksip_transport:get_listening(AppId, Proto)
    ],
    case lists:member({Ip, Port}, Listening) of
        true ->
            ok;
        false ->
            Spec = get_listener(AppId, Proto, Ip, Port, Opts),
            nksip_transport_sup:add_transport(AppId, Spec)
    end.


%% @doc Starts a new outbound connection.
-spec start_connection(nksip:sipapp_id(), nksip:protocol(),
                       inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | error.

start_connection(AppId, Proto, Ip, Port, Opts)
                    when Proto=:=tcp; Proto=:=tls ->
    Max = nksip_config:get(max_connections),
    case nksip_counters:value(nksip_transport_tcp) of
        Current when Current > Max ->
            error;
        _ ->
            CoreOpts = nksip_sipapp_srv:get_opts(AppId),
            case get_outbound(AppId, Proto, Ip, Port, Opts++CoreOpts) of
                {ok, Socket, Transport, Spec} ->
                    % Starts a new nksip_transport_tcp control process
                    {ok, Pid} = nksip_transport_sup:add_transport(AppId, Spec),
                    controlling_process(Proto, Socket, Pid),
                    setopts(Proto, Socket, [{active, once}]),
                    ?debug(AppId, "connected to ~s:~p (~p)", 
                           [nksip_lib:to_binary(Ip), Port, Proto]),
                    {ok, Pid, Transport};
                {error, Error} ->
                    ?info(AppId, "could not connect to ~s, ~p (~p): ~p", 
                          [nksip_lib:to_binary(Ip), Port, Proto, Error]),
                    error
            end
    end;

start_connection(_AppId, _Proto, _Ip, _Port, _Opts) ->
    error.


%% @private Finds a listening transport of Proto
-spec get_connected(nksip:sipapp_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number()) ->
    [{nksip_transport:transport(), pid()}].

get_connected(AppId, Proto, Ip, Port) ->
    nksip_proc:values({nksip_connection, {AppId, Proto, Ip, Port}}).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private Get supervisor spec for a new listening server
-spec get_listener(nksip:sipapp_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    term().

get_listener(AppId, udp, Ip, Port, _Opts) ->
    Transport = #transport{
        proto = udp,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    {
        {AppId, udp, Ip, Port}, 
        {nksip_transport_udp, start_link, [AppId, Transport]},
        permanent, 
        5000, 
        worker, 
        [nksip_transport_udp]
    };

get_listener(AppId, Proto, Ip, Port, Opts) when Proto=:=tcp; Proto=:=tls ->
    Listeners = nksip_lib:get_value(listeners, Opts, 1),
    Module = case Proto of
        tcp -> ranch_tcp;
        tls -> ranch_ssl
    end,
    Transport = #transport{
        proto = Proto,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = ranch:child_spec(
        {AppId, Proto, Ip, Port}, 
        Listeners, 
        Module,
        listen_opts(Proto, Ip, Port, Opts), 
        ?MODULE,
        [AppId, Transport]),
    % Little hack to use our start_link instead of ranch's one
    {ranch_listener_sup, start_link, StartOpts} = element(2, Spec),
    setelement(2, Spec, {?MODULE, ranch_start_link, StartOpts}).
    

%% @private Starts a new outbound connection and returns supervisor spec
-spec get_outbound(nksip:sipapp_id(), nksip:protocol(),
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, Port, Transport, Spec} | {error, term()}
    when Port::port()|ssl:sslsocket(), Transport::nksip_transport:transport(),
         Spec::term().
    
get_outbound(AppId, Proto, Ip, Port, Opts) when Proto=:=tcp; Proto=:=tls ->
    SocketOpts = outbound_opts(Proto, Opts),
    Host = nksip_lib:to_binary(Ip),
    Timeout = 64 * nksip_config:get(timer_t1),
    case connect(Proto, binary_to_list(Host), Port, SocketOpts, Timeout) of
        {ok, Socket} -> 
            {ok, {LocalIp, LocalPort}} = sockname(Proto, Socket),
            % If we have a listening transport of this class,
            % save it in the #transport{} to use later
            case nksip_transport:get_listening(AppId, Proto) of
                [] -> ListenIp = LocalIp, ListenPort = LocalPort;
                [{#transport{listen_ip=ListenIp, listen_port=ListenPort}, _Pid}|_] -> ok
            end,
             Transport = #transport{
                proto = Proto,
                local_ip = LocalIp,
                local_port = LocalPort,
                remote_ip = Ip,
                remote_port = Port,
                listen_ip = ListenIp,
                listen_port = ListenPort
            },
            {ok, Socket, Transport, {
                {AppId, Proto, Ip, Port, make_ref()},
                {nksip_transport_tcp, start_link, [AppId, Transport, Socket]},
                temporary,
                5000,
                worker,
                [nksip_transport_tcp]
            }};
        {error, Error} ->
            {error, Error}
    end.


%% @private Gets socket options for listening connections
-spec listen_opts(nksip:protocol(), inet:ip_address(), inet:port_number(), 
                    nksip_lib:proplist()) ->
    nksip_lib:proplist().

listen_opts(tcp, Ip, Port, _Opts) ->
    lists:flatten([
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]);

listen_opts(tls, Ip, Port, Opts) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "certificate.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = nksip_lib:get_value(certfile, Opts, DefCert),
    Key = nksip_lib:get_value(keyfile, Opts, DefKey),
    lists:flatten([
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end,
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]).


%% @private Gets socket options for outbound connections
-spec outbound_opts(nksip:protocol(), nksip_lib:proplist()) ->
    nksip_lib:proplist().

outbound_opts(Proto, Opts) ->
    Opts1 = listen_opts(Proto, {0,0,0,0}, 0, Opts),
    [binary|nksip_lib:delete(Opts1, [ip, port, max_connections])].


%% @private Our version of ranch_listener_sup:start_link/5
-spec ranch_start_link(any(), non_neg_integer(), module(), term(), module(), term())-> 
    {ok, pid()}.

ranch_start_link(Ref, NbAcceptors, RanchTransport, TransOpts, Protocol, 
                    [AppId, Transport]) ->
    case 
        ranch_listener_sup:start_link(Ref, NbAcceptors, RanchTransport, TransOpts, 
                                      Protocol, [AppId, Transport])
    of
        {ok, Pid} ->
            Port = ranch:get_port(Ref),
            Transport1 = Transport#transport{local_port=Port, listen_port=Port},
            nksip_proc:put(nksip_transports, {AppId, Transport1}, Pid),
            nksip_proc:put({nksip_listen, AppId}, Transport1, Pid),
            {ok, Pid};
        Other ->
            Other
    end.
   

%% @private Ranch's callback, called for every new inbound connection
-spec start_link(pid(), port(), atom(), term()) ->
    {ok, pid()}.

start_link(_ListenerPid, Socket, Module, [AppId, #transport{proto=Proto}=Transport]) ->
    {ok, {LocalIp, LocalPort}} = Module:sockname(Socket),
    {ok, {RemoteIp, RemotePort}} = Module:peername(Socket),
    Transport1 = Transport#transport{
        local_ip = LocalIp,
        local_port = LocalPort,
        remote_ip = RemoteIp,
        remote_port = RemotePort,
        listen_ip = LocalIp,
        listen_port = LocalPort
    },
    Module:setopts(Socket, [{nodelay, true}, {keepalive, true}]),
    ?debug(AppId, "new connection from ~p:~p (~p)", [RemoteIp, RemotePort, Proto]),
    nksip_transport_tcp:start_link(AppId, Transport1, Socket).


%% @private
connect(tcp, Host, Port, Opts, Timeout) ->
    gen_tcp:connect(Host, Port, Opts, Timeout);
connect(tls, Host, Port, Opts, Timeout) ->
    ssl:connect(Host, Port, Opts, Timeout).

%% @private
sockname(tcp, Socket) -> inet:sockname(Socket);
sockname(tls, Socket) -> ssl:sockname(Socket).

%% @private
controlling_process(tcp, Socket, Pid) -> 
    gen_tcp:controlling_process(Socket, Pid);
controlling_process(tls, Socket, Pid) -> 
    ssl:controlling_process(Socket, Pid).

%% @private
setopts(tcp, Socket, Opts) ->
    inet:setopts(Socket, Opts);
setopts(tls, Socket, Opts) ->
    ssl:setopts(Socket, Opts).




