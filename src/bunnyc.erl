%% The MIT License

%% Copyright (c) David Reid <dreid@dreid.org>, Andy Gross <andy@andygross.org>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
-module(bunnyc).
-author('Andy Gross <andy@andygross.org>').
-author('David Reid <dreid@dreid.org').

-behavior(gen_server).

-include("gen_bunny.hrl").
-include("push.hrl").

-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/3, stop/1]).
-export([declare/3,
         declare/4,
	 publish/3,
         publish/4,
         async_publish/3,
         async_publish/4,
         get/2,
         consume/2,
         ack/2,
         register_return_handler/2,
         register_flow_handler/2
        ]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%
%% API
%%
declare(Name, ConsumersPid, DeclareInfo) ->
    declare(Name, ConsumersPid, DeclareInfo, fun bunny_util:declare/2).

declare(Name, ConsumersPid, DeclareInfo, DeclareFun) ->
    gen_server:call(Name, {declare, ConsumersPid, DeclareInfo, DeclareFun}).

publish(Name, Key, Message) ->
    publish(Name, Key, Message, []).

publish(Name, Key, Message, Opts) ->
    gen_server:call(Name, {publish, Key, Message, Opts}).


async_publish(Name, Key, Message) ->
    async_publish(Name, Key, Message, []).

async_publish(Name, Key, Message, Opts) ->
    gen_server:cast(Name, {publish, Key, Message, Opts}).


get(Name, NoAck) ->
    gen_server:call(Name, {get, NoAck}).

consume(Name, Consumer) ->
    gen_server:call(Name, {consume, Consumer}).

ack(Name, Tag) ->
    gen_server:cast(Name, {ack, Tag}).


register_return_handler(Name, PID) when is_pid(PID) ->
    gen_server:cast(Name, {register_return_handler, PID}).


register_flow_handler(Name, PID) when is_pid(PID) ->
    gen_server:cast(Name, {register_flow_handler, PID}).


%% @doc Start the bunnyc gen_server as a locally registered process.
%% === ConnectionInfo ===
%% `ConnectionInfo' is passed as an argument to the connection fun, which by
%% default is {@link gen_bunny_mon:connect/1}. In this case, `ConnectionInfo' can
%% be any of the following types:
%% <ul>
%%
%% <li>`{network, Host, Port, {User, Pass}, VHost}', or `{network, #amqp_params{} }':
%% Connects to RabbitMQ over TCP, using the supplied parameters. When using the
%% tuple form, each term after Host is optional. For any parameters not
%% supplied, the defaults in the #amqp_params{} record definition are used.
%% The default values are currently:
%% ```
%% {username          = <<"guest">>,
%%  password          = <<"guest">>,
%%  virtual_host      = <<"/">>,
%%  host              = "localhost",
%%  port              = 5672,
%%  channel_max       = 0,
%%  frame_max         = 0,
%%  heartbeat         = 0,
%%  ssl_options       = none,
%%  client_properties = []}
%% '''
%% </li>
%%
%% <li>`direct' or `{direct, #amqp_params{} }': Connect to RabbitMQ using native
%% Erlang messaging. See [http://www.rabbitmq.com/erlang-client-user-guide.html]
%% </li>
%% </ul>
%%
%% === DeclareInfo ===
%% `DeclareInfo' is passed as an argument to the declare fun, which by default
%% is {@link bunny_util:declare/2}. In this case, `DeclareInfo' can be any of the
%% following:
%% <ul>
%% <li>`NameForEverything' (binary()): gen_bunny will declare an exchange and a
%% queue with this name, and bind the queue to the exchange with a routing key of
%% the same name.</li>
%% <li>`{Exchange}': `Exchange' can be a binary() name, or an
%% #'exchange.declare_ok'{} record.</li>
%% <li>`{Exchange, Queue, RoutingKey}': `Exchange' is as described above.
%% `Queue' may be a binary() name or a  #'queue.declare_ok'{} record. RoutingKey
%% is a binary().</li>
%% </ul>
%%
%% === Args ===
%% `Args' is a property list. If the key `connect_fun' is supplied, that fun
%% will be used in place of the default connection fun described above. Likewise,
%% if the key `declare_fun' is given, the associated value will be used in
%% place of the default declare fun described above.
start_link(Name, ConnectionInfo, Args) ->
    application:start(xmerl),
    application:start(rabbit_common),
    application:start(amqp_client),
    application:start(gen_bunny),
    gen_server:start_link({local, Name}, ?MODULE,
                          [ConnectionInfo, Args], []).


stop(Name) ->
    gen_server:call(Name, stop).


%%
%% Callbacks
%%

%% @private
init([ConnectionInfo, Args]) ->
    ?ewp_msg("~p init~n", [self()]),
    ConnectFun = proplists:get_value(connect_fun, Args,
                                     fun gen_bunny_mon:connect/1),

    {ok, {ConnectionPid, ChannelPid}} = ConnectFun(ConnectionInfo),

    {ok, #bunnyc_state{connection=ConnectionPid,
                channel=ChannelPid}}.

%% @private
handle_call({declare, ConsumersPid, DeclareInfo, DeclareFun}, _From,
            State = #bunnyc_state{connection=ConnectionPid, channel=ChannelPid}) ->
    {ok, {Exchange, Queue}} = DeclareFun(ChannelPid, DeclareInfo),
    {reply, {Exchange, Queue}, State#bunnyc_state{exchange=Exchange, queue=Queue, consumersPid = ConsumersPid}};

handle_call({publish, Key, Message, Opts}, _From,
            State = #bunnyc_state{channel=Channel, exchange=Exchange})
  when is_binary(Key), is_binary(Message) orelse ?is_message(Message),
       is_list(Opts) ->
    Resp = internal_publish(fun amqp_channel:call/3,
                            Channel, Exchange, Key, Message, Opts),
    {reply, Resp, State};

handle_call({get, NoAck}, _From,
            State = #bunnyc_state{channel=Channel, queue=Queue}) ->
    Resp = internal_get(Channel, Queue, NoAck),
    {reply, Resp, State};

handle_call({consume, Consumer}, _From,
            State = #bunnyc_state{channel=Channel, queue=Queue}) ->
    Resp = internal_consume(Channel, Queue, Consumer),
    {reply, Resp, State};


handle_call(stop, _From,
            State = #bunnyc_state{channel=Channel, connection=Connection}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    {stop, normal, ok, State}.

%% @private
handle_cast({publish, Key, Message, Opts},
            State = #bunnyc_state{channel=Channel, exchange=Exchange})
  when is_binary(Key), is_binary(Message) orelse ?is_message(Message),
       is_list(Opts) ->
    internal_publish(fun amqp_channel:cast/3,
                     Channel, Exchange, Key, Message, Opts),
    {noreply, State};

handle_cast({ack, Tag}, State = #bunnyc_state{channel=Channel}) ->
    internal_ack(Channel, Tag),
    {noreply, State};

handle_cast({register_return_handler, PID}, State = #bunnyc_state{ channel = Channel }) ->
    internal_register_return_handler(Channel, PID),
    {noreply, State#bunnyc_state{return_handler_pid = PID}};

handle_cast({register_flow_handler, PID}, State = #bunnyc_state{ channel = Channel }) ->
    internal_register_flow_handler(Channel, PID),
    {noreply, State#bunnyc_state{flow_handler_pid = PID}};

handle_cast(_Request, State) ->
    {noreply, State}.

%% @private
handle_info({reconnected, {ConnectionPid, ChannelPid}},
            #bunnyc_state{return_handler_pid = ReturnHandlerPid,
                          flow_handler_pid = FlowHandlerPid,
			  consumersPid = ConsumersPid} = State) ->
    internal_register_return_handler(ChannelPid, ReturnHandlerPid),
    internal_register_flow_handler(ChannelPid, FlowHandlerPid),
    ?ewp_msg("this is bunnyc is received reconnect ~p~n", [ConsumersPid]),
    case is_process_alive(ConsumersPid) of
        true ->
		self() ! {reconsume, ConsumersPid};
	false ->
		ok
    end,
    {noreply, State#bunnyc_state{connection=ConnectionPid, channel=ChannelPid}};
handle_info({reconsume, Consumer}, State) ->
    Consumer ! reconsume,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%
%% Internal
%%
internal_publish(Fun, Channel, Exchange, Key, Message, Opts)
  when ?is_message(Message) ->
    Mandatory = proplists:get_value(mandatory, Opts, false),
    Immediate = proplists:get_value(immediate, Opts, false),

    BasicPublish = #'basic.publish'{
      exchange = bunny_util:get_name(Exchange),
      routing_key = Key,
      mandatory = Mandatory,
      immediate = Immediate},

    Fun(Channel, BasicPublish, Message);
internal_publish(Fun, Channel, Exchange, Key, Message, Opts)
  when is_binary(Message) ->
    internal_publish(Fun, Channel, Exchange, Key,
                     bunny_util:new_message(Message), Opts).

internal_get(Channel, Queue, NoAck) ->
    amqp_channel:call(Channel, #'basic.get'{queue=bunny_util:get_name(Queue),
                                            no_ack=NoAck}).

internal_consume(Channel, Queue, Consumer) ->
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = 100}),
    amqp_channel:subscribe(Channel, #'basic.consume'{queue = bunny_util:get_name(Queue)}, Consumer).

internal_ack(Channel, DeliveryTag) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag=DeliveryTag}).

internal_register_return_handler(_Channel, undefined) -> ok;
internal_register_return_handler(Channel, PID) ->
    amqp_channel:register_return_handler(Channel, PID).

internal_register_flow_handler(_Channel, undefined) -> ok;
internal_register_flow_handler(Channel, PID) ->
    amqp_channel:register_flow_handler(Channel, PID).
