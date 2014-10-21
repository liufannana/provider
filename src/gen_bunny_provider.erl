-module(gen_bunny_provider).
-author('LiuFan <liufanyansha@sina.cn>').
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-include("gen_bunny.hrl").
-include("ewp.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1,
		 publish/3,
		 publish/4]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


-record(state, {connection,
				channel,
				connection_info,
				declare_info,
				exchanges,
				rules = dict:new(),
				status = invalid
				}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%%	Config = {rabbit1,
%%					{"192.168.22.132", 5672, {<<"guest">>, <<"guest">>}, <<"/">>},
%%			      	{[{<<"android">>, []}], 
%%			      	 [{<<"queue1">>, []}], 
%%			      	 [{<<"android">>, <<"queue1">>, <<"android.queue1">>}]
%%			      	}}
%% ------------------------------------------------------------------
start_link(Config) ->
	{Name, ConnectionInfo, DeclareInfo} = Config,
	gen_server:start_link({local, Name}, ?MODULE, [ConnectionInfo, DeclareInfo], []).

publish(Name, Key, Payload) ->
	publish(Name, Key, Payload, []).

publish(Name, Key, Payload, Opts) ->
	gen_server:call(Name, {publish, Key, Payload, Opts}, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([ConnectionInfo, DeclareInfo]) ->
	self() ! connect,
    {ok, #state{connection_info = ConnectionInfo,
    			declare_info = DeclareInfo}}.

handle_call({publish, Key, Payload, Opts}, _From, State = #state{channel = Channel, status = valid, rules = Rules}) ->
	Exchange = get_exchange(Key, Rules),
	Resp = internal_publish(fun amqp_channel:call/3,
                            Channel, Exchange, Key, Payload, Opts),
    {reply, Resp, State};
handle_call({publish, _Key, _Payload, _Opts}, _From, State = #state{status = invalid}) ->
	Resp = {error, invalid},
    {reply, Resp, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, State = #state{connection_info = ConnectionInfo}) ->
	{ok, {ConnectionPid, ChannelPid}} = gen_bunny_mon:connect(ConnectionInfo),
	self() ! declare,
	{noreply, State#state{connection = ConnectionPid,
							channel = ChannelPid}};
handle_info(declare, State = #state{channel = Channel, declare_info = DeclareInfo, rules = Rules}) ->
	{ExchangesInfo, QueuesInfo, BindgingsInfo}= DeclareInfo,

	{ok, Exchanges} = declare_exchanges(Channel, ExchangesInfo, []),
	ok = declare_queues(Channel, QueuesInfo),
	{ok, NewRules} = do_bindings(Channel, BindgingsInfo,Rules),
	{noreply, State#state{exchanges = Exchanges, rules = NewRules, status = valid}};
handle_info({reconnected, {ConnectionPid, ChannelPid}}, State) ->
	self() ! declare,
	{noreply, State#state{connection = ConnectionPid,
							channel = ChannelPid}};
handle_info({invalid, channel_pid}, State) ->
	{noreply, State#state{status = invalid}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
internal_publish(Fun, Channel, Exchange, Key, Message, Opts)
  when ?is_message(Message) ->
    Mandatory = proplists:get_value(mandatory, Opts, false),
    Immediate = proplists:get_value(immediate, Opts, false),

    BasicPublish = #'basic.publish'{
      exchange = Exchange,
      routing_key = Key,
      mandatory = Mandatory,
      immediate = Immediate},
    Fun(Channel, BasicPublish, Message);
internal_publish(Fun, Channel, Exchange, Key, Message, Opts)
  when is_binary(Message) ->
    internal_publish(Fun, Channel, Exchange, Key,
                     bunny_util:new_message(Message), Opts).

declare_exchanges(_Channel, [], Exchanges) ->
	{ok, Exchanges};
declare_exchanges(Channel, [{Name, _Opts}|Rest], Exchanges) ->
	Exchange = #'exchange.declare'{exchange=Name, durable = true},
	#'exchange.declare_ok'{} = amqp_channel:call(
                               Channel,
                               Exchange),
    declare_exchanges(Channel, Rest, [Exchange|Exchanges]).

declare_queues(_Channel, []) ->
	ok;
declare_queues(Channel, [{Name, _Opts}|Rest]) ->
	Queue = #'queue.declare'{queue=Name,durable=true},
	#'queue.declare_ok'{} = amqp_channel:call(
                                 Channel,
                                 Queue),
    declare_queues(Channel, Rest).

do_bindings(_Channel, [], Rules) ->
	{ok, Rules};
do_bindings(Channel, [{Exchange, Queue, RoutingKey}|Rest], Rules) ->
	Binding = #'queue.bind'{queue=Queue,
                            exchange=Exchange,
                            routing_key=RoutingKey},
    NewRules = add_rule(Rules, RoutingKey, Exchange),
    #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    do_bindings(Channel, Rest, NewRules).

add_rule(Rules, RoutingKey, Exchange) ->
	NewRules = case dict:find(RoutingKey, Rules) of
		error ->
			dict:store(RoutingKey, [Exchange], Rules);
		{ok, Value} ->
			dict:store(RoutingKey, [Exchange|Value], Rules)
	end,
	NewRules.

get_exchange(RoutingKey, Rules) ->
	case dict:find(RoutingKey, Rules) of
		error ->
			{error, no_exchange};
		{ok, Value} ->
			bunny_util:get_one(Value)
	end.	