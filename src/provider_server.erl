-module(provider_server).
-author('LiuFan <liufanyansha@sina.cn>').

-include("gen_bunny.hrl").

-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
		 publish/2,
		 publish/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {connections = []}).
%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% lists:map(fun(X) -> 
%%				provider_server:publish(<<"push.android">>,
%%										<<"{\"app\":\"push\",\"platform\":\"android\",\"message\":\"\",\"alert\":\"\",\"title\":\"\",\"message_type\":\"\",\"tokens\":[{\"token\":\"11111111111111111\"}]}">>)
%%			 end, lists:seq(1,100000)).
publish(RoutingKey, Payload) ->
	publish(RoutingKey, Payload, []).
publish(RoutingKey, Payload, Opts) ->
	gen_server:call(?SERVER, {publish, RoutingKey, Payload, Opts}, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
	{ok, Config} = application:get_env(connections),
	Connections = start_providers(Config, []),
    {ok, #state{connections = Connections}}.

handle_call({publish, RoutingKey, Payload, Opts}, _From, State = #state{connections = Connections}) ->
	Connection = bunny_util:get_one(Connections),
	Reply = gen_bunny_provider:publish(Connection, RoutingKey, Payload, Opts),
	{reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

start_providers([], Connections) ->
	Connections;
start_providers([Config = {Name, _ConnectionInfo, _DeclareInfo}|Rest], Connections) ->
	{ok, _} = gen_bunny_provider_sup:start_child(gen_bunny_provider, Config),
	start_providers(Rest, [Name|Connections]).

