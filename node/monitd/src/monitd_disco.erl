%%%----------------------------------------------------------------------
%%% File    : monitd_disco.erl
%%% Author  : Ery Lee <ery.lee@gmail.com>
%%% Purpose : Discovery task executor.
%%% Created : 22 Oct. 2008
%%% License : http://www.opengoss.com/
%%%
%%% Copyright (C) 2012, www.opengoss.com 
%%%----------------------------------------------------------------------
-module(monitd_disco).

-include("mib/rfc1213.hrl").

-include_lib("mit/include/mit.hrl").

-include_lib("elog/include/elog.hrl").

-import(extbif, [to_list/1]).

-import(proplists,[get_value/2, get_value/3]).

-behavior(gen_server).

%%api
-export([start_link/0, 
		setup/1,
        status/0,
        discover/1,
        undiscover/1,
        update/1,
        report/1]).

%%callback
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(sysmod, {sysoid, category, vendor, model, mib}). %category, vendor,

-record(sysmapper, {sysoid, name, module, mib}).

%%--------------------------------------------------------------------
%% @spec start_link() ->  Result
%%   Result = {ok,Pid} | ignore | {error,Error}
%% @doc calls gen_server:start_link
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

setup({dict_status, Records}) ->
    gen_server:call(?MODULE, {setup, dict_status, Records});

setup({sysoids, Sysoids}) ->
	gen_server:call(?MODULE, {setup, sysoids, Sysoids}).

setup({sysmappers, Mappers}) ->
	gen_server:call(?MODULE, {setup, sysmappers, Mappers}).

status() ->
    gen_server:call(?MODULE, status).

discover(Node) when is_record(Node, mit_node) ->
    gen_server:cast(?MODULE, {discover, Node}).

undiscover(Dn) ->
    gen_server:cast(?MODULE, {undiscover, Dn}).

update(Node) when is_record(Node, mit_node) ->
    gen_server:cast(?MODULE, {update, Node}).

report({failure, Node}) -> 
    gen_server:cast(?MODULE, {failure, Node});

report({success, Dn, DataList}) ->
    gen_server:cast(?MODULE, {success, Dn, DataList}).

%%--------------------------------------------------------------------
%% @hidden
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    ets:new(dict_status, [set, named_table, protected]),
    ets:new(sysmod, [set, named_table, protected, {keypos, 2}]),
    ets:new(sysmapper, [bag, named_table, protected, {keypos, 2}]),
    ets:new(disco_table, [set, named_table]),
    ets:new(failed_disco_table, [set, named_table]),
    erlang:send_after(1000, self(), execute),
    ?INFO_MSG("monitd_disco is starting...[ok]"),
    {ok, state}.

handle_call(status, _From, State) ->
    Reply = [{pending, ets:info(disco_table, size)},
        {failed, ets:info(failed_disco_table, size)}],
    {reply, Reply, State};

handle_call({setup, dict_status, Records}, _From, State) ->
    lists:foreach(fun(Record) ->
        Vendor = get_value(vendor, Record),
        Kind = get_value(kind, Record),
        Device_type = get_value(device_type, Record),
        Status_type = get_value(status_type, Record),
        Status_o = get_value(status_o, Record),
        Status_c = get_value(status_c, Record),
        [ets:insert(dict_status, {{Vendor,Kind,Device_type,Status_type,list_to_binary(S)}, Status_c})
            || S <- string:tokens(binary_to_list(Status_o),",")]
    end, Records),
    {reply, ok, State};

handle_call({setup, sysoids, Records}, _Form, State) ->
    ?INFO("setup sysoids: ~p", [length(Records)]),
    [ets:insert(sysmod, 
        #sysmod{
            sysoid = get_value(sysoid, R),
            category = extbif:binary_to_atom(get_value(category, R)),
            vendor = extbif:binary_to_atom(get_value(vendor, R)),
            model = extbif:binary_to_atom(get_value(model, R)),
            module = extbif:binary_to_atom(get_value(disco, R))}) 
    || R <- Records],
    {reply, ok, State};

handle_call({setup, sysmappers, Mappers}, _From, State) ->
    [ets:insert(sysmapper, 
        #sysmapper{
            sysoid = get_value(sysoid, R),
            name = extbif:binary_to_atom(get_value(name, R)),
            module = extbif:binary_to_atom(get_value(module, R)),
            mib =extbif:binary_to_atom(get_value(mib, R))
        }
    || R <- Mappers],
    {reply, ok, State};
    
handle_call(Req, _From, State) ->
    ?ERROR("badreq: ~p", [Req]),
    {stop, {badreq, Req}, State}.

handle_cast({discover, #mit_node{dn=Dn}=Node}, State) ->
    ets:insert(disco_table, {Dn, Node}),
    {noreply, State};

handle_cast({update, #mit_node{dn=Dn}=Node}, State) ->
    case ets:lookup(disco_table, Dn) of
    [_] -> 
        ets:insert(disco_table, {Dn, Node});
    [] -> 
        ok
    end,
    case ets:lookup(failed_disco_table, Dn) of
    [_] -> 
        ets:insert(failed_disco_table, {Dn, Node});
    [] -> 
        ok
    end,
    {noreply, State};

handle_cast({undiscover, Dn}, State) ->
    ets:delete(disco_table, Dn),
    ets:delete(failed_disco_table, Dn),
    {noreply, State};

handle_cast({failure, #mit_node{dn=Dn}=Node}, State) ->
    ets:insert(failed_disco_table, {Dn, Node}),
    {noreply, State};

handle_cast({success, Dn, DataList}, State) ->
    ets:delete(failed_disco_table, Dn),
    monitd_hub:emit(DataList),
    {noreply, State};

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

handle_info(execute, State) ->
    First = ets:first(disco_table),
    case First of
    '$end_of_table' ->
        pass;
     Dn ->
        [{_Dn, Node}] = ets:lookup(disco_table, Dn),
        spawn(fun() -> execute({Dn, Node}) end),
        ets:delete(disco_table, Dn)
    end,
    erlang:send_after(1000, self(), execute),
    {noreply, State};

handle_info(rediscovery, State) ->
    ?INFO_MSG("begin to rediscovery..."),
    AgentPid = self(),
    spawn(fun() -> 
            rediscover(ets:first(disco_table)),
            erlang:send_after(15*60*1000, AgentPid, rediscovery)
          end),
    {noreply, State};

handle_info(Info, State) ->
    {stop, {badinfo, Info}, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

rediscover('$end_of_table') ->
    ok;

rediscover(Dn) ->
    [{Dn, Node}] = ets:lookup(disco_table, Dn),
    execute({Dn, Node}),
    ?INFO("rediscovering ~s", [Dn]),
    rediscover(ets:next(disco_table, Dn)).

execute({Dn, Node}) ->
    %TODO: Discovery State?
    case catch discover(node, Node) of
    {ok, DataList} -> 
      report({success, Dn, DataList});
    ignore ->
        ignore;
    {error, Error} ->
      report({failure, Node}),
      ?ERROR("Failed to discover ~p: ~p", [Dn, Error]);
    {'EXIT', Reason} ->
      ?ERROR("Exception occurred when discover ~p: ~n ~p ~n ~p", [Dn, Reason, Node]);
    Throw ->
      ?ERROR("throw: ~p, dn: ~p", [Throw, Dn])
    end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
discover(node, #mit_node{ip=undefined}) ->
    ignore;
discover(node, #mit_node{dn=Dn, ip=Ip, community=Community}) ->
	?INFO("begin to discover ~s", [Ip]),

	{SnmpStatus, _} = check_snmp:run(to_list(Ip), Community),

	Agent = [{community, Community}],
	discover(SnmpStatus, node, Dn, binary_to_list(Ip), Agent).

discover("SNMP OK", node, Dn, Ip, Agent) ->
  case snmp_mapping:discovery(Ip, ?System, Agent) of
    {ok, Values} ->
      {value, SysName} = dataset:get_value(sysName, Values),
      {value, SysDescr} = dataset:get_value(sysDescr, Values),
      {value, SysObjectID} = dataset:get_value(sysObjectID, Values),
      SysOid = mib_oid:to_str(SysObjectID),
      Attrs = [{sysdescr, SysDescr}, {sysname, SysName}, {sysoid, SysOid}],
      case ets:lookup(sysmod, list_to_binary(SysOid)) of 
        [#sysmod{category=Category, model=ModelId, module=Mod, mib=Mib}] -> 
          Attrs1 = [{model_id, ModelId} | Attrs],
          {ok, SpecAttrs, DataList} = Mod:disco(Dn, Ip, Agent, [{mib, Mib}]),
          ?INFO("DiscoMod: ~s, model: ~p, Ip: ~s",[Mod, ModelId, Ip]),
		  Attrs2 = Attrs1 ++ SpecAttrs,
          {ok, [{node, Category, Dn, Attrs2} | DataList]};
        [] ->
          ?ERROR("No disco mod for: ~s, ip: ~s, sysdescr: ~s", [SysOid, Ip, SysDescr]),
          {error, no_sysmod};
        {error, Reason} ->
          {error, Reason}
      end;
    {error, Error} -> 
      {error, Error}
  end;

discover("SNMP problem", _Type, _Dn, Ip, _AgentData) ->
  {error, "SNMP problem: " ++ Ip};

discover(SnmpStatus, _Type, _Dn, _Ip, _AgentData) ->
  {error, "Unknown SnmpStatus: " ++ SnmpStatus}.

