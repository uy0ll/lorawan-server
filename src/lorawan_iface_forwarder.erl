%
% Copyright (c) 2016 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
% Gateway interface for the https://github.com/Lora-net/packet_forwarder
% Supports protocol v2.2.0
% See https://github.com/Lora-net/packet_forwarder/blob/master/PROTOCOL.TXT
%
-module(lorawan_iface_forwarder).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("lorawan.hrl").

-record(state, {sock, pulladdr}).

start_link(Port) ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [Port], []).

init([Port]) ->
    {ok, Socket} = gen_udp:open(Port, [binary]),
    {ok, #state{sock=Socket}}.

handle_call(_Request, _From, State) ->
    {stop, {error, unknownmsg}, State}.

handle_cast({send, Packet}, #state{sock=Socket, pulladdr={Host, Port}}=State) ->
    % PULL RESP
    gen_udp:send(Socket, Host, Port, <<1, 0:16, 3, Packet/binary>>),
    {noreply, State};
handle_cast(_Req, State) ->
    lager:info("Downlink request ignored. Gateway not connected."),
    {noreply, State}.

% PUSH DATA
handle_info({udp, Socket, Host, Port, <<1, Token:16, 0, MAC:8/binary, Data/binary>>}, #state{sock=Socket}=State) ->
    Data2 = jsx:decode(Data, [{labels, atom}]),
    % PUSH ACK
    gen_udp:send(Socket, Host, Port, <<1, Token:16, 1>>),
    lists:foreach(
        fun ({rxpk, Pk}) -> rxpk(MAC, Pk);
            ({stat, Pk}) -> status(MAC, Pk)
        end, Data2),
    {noreply, State};

% PULL DATA
handle_info({udp, Socket, Host, Port, <<1, Token:16, 2, _MAC:8/binary>>}, #state{sock=Socket}=State) ->
    % PULL ACK
    gen_udp:send(Socket, Host, Port, <<1, Token:16, 4>>),
    {noreply, State#state{pulladdr={Host, Port}}}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


rxpk(_MAC, []) -> ok;
rxpk(MAC, [Pk|More]) ->
    {RxQ, RF, PHYPayload} = parse_rxpk(Pk),
    Size = byte_size(PHYPayload)-4,
    <<Msg:Size/binary, MIC:4/binary>> = PHYPayload,
    <<MType:3, _:5, _/binary>> = Msg,
    case lorawan_mac:process_frame(RxQ, RF, MType, Msg, MIC) of
        ok -> ok;
        {send, Time2, RF2, PHYPayload2} ->
            txsend(Time2, RF2, PHYPayload2);
        {error, Error} ->
            lager:error("ERROR: ~w", [Error])
    end,
    rxpk(MAC, More).

status(_MAC, Pk) ->
    S = ?to_record(stat, Pk),
    %% TODO: what shall we do with this information?
    %lager:debug("rxnb ~w, rxok ~w, rxfw ~w, ackr ~w, dwnb ~w, txnb ~w",
    %    [S#stat.rxnb, S#stat.rxok, S#stat.rxfw, S#stat.ackr, S#stat.dwnb, S#stat.txnb]),
    ok.

txsend(Time, RF, PHYPayload) ->
    % TX only supported on radio A
    Pk = jsx:encode([{txpk, build_txpk(#txq{tmst=Time, rfch=0, powe=14}, RF, PHYPayload)}]),
    gen_server:cast({global, ?MODULE}, {send, Pk}).

parse_rxpk(Pk) ->
    Data = base64:decode(proplists:get_value(data, Pk)),
    case proplists:get_value(modu, Pk) of
        <<"LORA">> -> {?to_record(rxq, Pk), ?to_record(rflora, Pk), Data}
    end.

build_txpk(TxQ, RF, Data) ->
    ?to_proplist(txq, TxQ) ++ ?to_proplist(rflora, RF) ++ 
        [{imme, false}, {modu, <<"LORA">>}, {ipol, true}, {size, byte_size(Data)}, {data, base64:encode(Data)}].

% end of file
