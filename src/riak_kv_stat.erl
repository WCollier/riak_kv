%% -------------------------------------------------------------------
%%
%% riak_stat: collect, aggregate, and provide stats about the local node
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc riak_kv_stat is a module for aggregating
%%      stats about the Riak node on which it is runing.
%%
%%      Update each stat with the exported function update/1. Add
%%      a new stat to the internal stats/0 func to register a new stat with
%%      folsom.
%%
%%      Get the latest aggregation of stats with the exported function
%%      get_stats/0. Or use folsom_metrics:get_metric_value/1,
%%      or riak_core_stat_q:get_stats/1.
%%

-module(riak_kv_stat).

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/0, get_stats/0,
         update/1, perform_update/1, register_stats/0, produce_stats/0,
         leveldb_read_block_errors/0, stat_update_error/3, stop/0]).
-export([track_bucket/1, untrack_bucket/1]).
-export([active_gets/0, active_puts/0]).

-export([report_legacy/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, monitor_loop/1]).

-record(state, {repair_mon, monitors}).

-define(SERVER, ?MODULE).
-define(APP, riak_kv).
-define(PFX, riak_core_stat:prefix()).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register_stats() ->
    riak_core_stat:register_stats(?APP, stats()).

%% @spec get_stats() -> proplist()
%% @doc Get the current aggregation of stats.
get_stats() ->
    riak_kv_wm_stats:get_stats().


%% Creation of a dynamic stat _must_ be serialized.
register_stat(Name, Type) ->
    do_register_stat(Name, Type).
%% gen_server:call(?SERVER, {register, Name, Type}).

update(Arg) ->
    maybe_dispatch_to_sidejob(erlang:module_loaded(riak_kv_stat_sj), Arg).

maybe_dispatch_to_sidejob(true, Arg) ->
    riak_kv_stat_worker:update(Arg);
maybe_dispatch_to_sidejob(false, Arg) ->
    try perform_update(Arg) catch Class:Error ->
       stat_update_error(Arg, Class, Error)
    end,
    ok.

stat_update_error(Arg, Class, Error) ->
    lager:debug("Failed to update stat ~p due to (~p) ~p.", [Arg, Class, Error]).

%% @doc
%% Callback used by a {@link riak_kv_stat_worker} to perform actual update
perform_update(Arg) ->
    do_update(Arg).

track_bucket(Bucket) when is_binary(Bucket) ->
    riak_core_bucket:set_bucket(Bucket, [{stat_tracked, true}]).

untrack_bucket(Bucket) when is_binary(Bucket) ->
    riak_core_bucket:set_bucket(Bucket, [{stat_tracked, false}]).

%% The current number of active get fsms in riak
active_gets() ->
    counter_value([?PFX, ?APP, node, gets, fsm, active]).

%% The current number of active put fsms in riak
active_puts() ->
    counter_value([?PFX, ?APP, node, puts, fsm, active]).

counter_value(Name) ->
    case exometer:get_value(Name, [value]) of
	{ok, [{value, N}]} ->
	    N;
	_ ->
	    0
    end.

stop() ->
    gen_server:cast(?SERVER, stop).

%% gen_server

init([]) ->
    register_stats(),
    Me = self(),
    State = #state{monitors = [{index, spawn_link(?MODULE, monitor_loop, [index])},
                               {list, spawn_link(?MODULE, monitor_loop, [list])}],
                   repair_mon = spawn_monitor(fun() -> stat_repair_loop(Me) end)},
    {ok, State}.

handle_call({register, Name, Type}, _From, State) ->
    Rep = do_register_stat(Name, Type),
    {reply, Rep, State}.

handle_cast({monitor, Type, Pid}, State) ->
    case proplists:get_value(Type, State#state.monitors) of
        Monitor when is_pid(Monitor) ->
            Monitor ! {add_pid, Pid};
        _ -> lager:error("Couldn't find process for ~p to add monitor", [Type])
    end,
    {noreply, State};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Req, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, _Cause}, State=#state{repair_mon={Pid, MonRef}}) ->
    Me = self(),
    RepairMonitor = spawn_monitor(fun() -> stat_repair_loop(Me) end),
    {noreply, State#state{repair_mon=RepairMonitor}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @doc Update the given stat
do_update({vnode_get, Idx, USecs}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, vnode, gets], 1),
    ok = create_or_update([P, ?APP, vnode, gets, time], USecs, histogram),
    do_per_index(gets, Idx, USecs);
do_update({vnode_put, Idx, USecs}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, vnode, puts], 1),
    ok = create_or_update([P, ?APP, vnode, puts, time], USecs, histogram),
    do_per_index(puts, Idx, USecs);
do_update(vnode_index_refresh) ->
    P = ?PFX,
    exometer:update([P, ?APP, vnode, index, refreshes], 1);
do_update(vnode_index_read) ->
    P = ?PFX,
    exometer:update([P, ?APP, vnode, index, reads], 1);
do_update({vnode_index_write, PostingsAdded, PostingsRemoved}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, vnode, index, writes], 1),
    ok = exometer:update([P, ?APP, vnode, index, writes, postings], PostingsAdded),
    exometer:update([P, ?APP, vnode, index, deletes, postings], PostingsRemoved);
do_update({vnode_index_delete, Postings}) ->
    P = riak_core_stat:prefix(),
    ok = exometer:update([P, ?APP, vnode, index, deletes], Postings),
    exometer:update([P, ?APP, vnode, index, deletes, postings], Postings);
do_update({vnode_dt_update, Mod, Micros}) ->
    P = ?PFX,
    Type = riak_kv_crdt:from_mod(Mod),
    ok = create_or_update([P, ?APP, vnode, Type, update], 1, spiral),
    create_or_update([P, ?APP, vnode, Type, update, time], Micros, histogram);
do_update({riak_object_merge, undefined, Micros}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, object, merge], 1),
    exometer:update([P, ?APP, object, merge, time], Micros);
do_update({riak_object_merge, Mod, Micros}) ->
    P = ?PFX,
    Type = riak_kv_crdt:from_mod(Mod),
    ok = create_or_update([P, ?APP, object, Type, merge], 1, spiral),
    create_or_update([P, ?APP, object, Type, merge, time], Micros, histogram);
do_update({get_fsm, Bucket, Microsecs, Stages, undefined, undefined, PerBucket, undefined}) ->
    P = riak_core_stat:prefix(),
    ok = exometer:update([P, ?APP, node, gets], 1),
    ok = exometer:update([P, ?APP, node, gets, time], Microsecs),
    ok = do_stages([P, ?APP, node, gets, time], Stages),
    do_get_bucket(PerBucket, {Bucket, Microsecs, Stages, undefined, undefined});
do_update({get_fsm, Bucket, Microsecs, Stages, NumSiblings, ObjSize, PerBucket, undefined}) ->
    P = riak_core_stat:prefix(),
    ok = exometer:update([P, ?APP, node, gets], 1),
    ok = exometer:update([P, ?APP, node, gets, time], Microsecs),
    ok = exometer:update([P, ?APP, node, gets, siblings], NumSiblings),
    ok = exometer:update([P, ?APP, node, gets, objsize], ObjSize),
    ok = do_stages([P, ?APP, node, gets, time], Stages),
    do_get_bucket(PerBucket, {Bucket, Microsecs, Stages, NumSiblings, ObjSize});
do_update({get_fsm, Bucket, Microsecs, Stages, undefined, undefined, PerBucket, CRDTMod}) ->
    P = riak_core_stat:prefix(),
    Type = riak_kv_crdt:from_mod(CRDTMod),
    ok = create_or_update([P, ?APP, node, gets, Type], 1, spiral),
    ok = create_or_update([P, ?APP, node, gets, Type, time], Microsecs, histogram),
    ok = do_stages([P, ?APP, node, gets, Type, time], Stages),
    do_get_bucket(PerBucket, {Bucket, Microsecs, Stages, undefined, undefined, Type});
do_update({get_fsm, Bucket, Microsecs, Stages, NumSiblings, ObjSize, PerBucket, CRDTMod}) ->
    P = ?PFX,
    Type = riak_kv_crdt:from_mod(CRDTMod),
    ok = create_or_update([P, ?APP, node, gets, Type], 1, spiral),
    ok = create_or_update([P, ?APP, node, gets, Type, time], Microsecs, histogram),
    ok = create_or_update([P, ?APP, node, gets, Type, siblings], NumSiblings, histogram),
    ok = create_or_update([P, ?APP, node, gets, Type, objsize], ObjSize, histogram),
    ok = do_stages([P, ?APP, node, gets, Type, time], Stages),
    do_get_bucket(PerBucket, {Bucket, Microsecs, Stages, NumSiblings, ObjSize, Type});
do_update({put_fsm_time, Bucket,  Microsecs, Stages, PerBucket, undefined}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, node, puts], 1),
    ok = exometer:update([P, ?APP, node, puts, time], Microsecs),
    ok = do_stages([P, ?APP, node, puts, time], Stages),
    do_put_bucket(PerBucket, {Bucket, Microsecs, Stages});
do_update({put_fsm_time, Bucket,  Microsecs, Stages, PerBucket, CRDTMod}) ->
    P = ?PFX,
    Type = riak_kv_crdt:from_mod(CRDTMod),
    ok = create_or_update([P, ?APP, node, puts, Type], 1, spiral),
    ok = create_or_update([P, ?APP, node, puts, Type, time], Microsecs, histogram),
    ok = do_stages([P, ?APP, node, puts, Type, time], Stages),
    do_put_bucket(PerBucket, {Bucket, Microsecs, Stages, Type});
do_update({read_repairs, Indices, Preflist}) ->
    ok = exometer:update([?PFX, ?APP, node, gets, read_repairs], 1),
    do_repairs(Indices, Preflist);
do_update(skipped_read_repairs) ->
    ok = exometer:update([?PFX, ?APP, node, gets, skipped_read_repairs], 1);
do_update(coord_redir) ->
    exometer:update([?PFX, ?APP, node, puts, coord_redirs], 1);
do_update(mapper_start) ->
    exometer:update([?PFX, ?APP, mapper_count], 1);
do_update(mapper_end) ->
    exometer:update([?PFX, ?APP, mapper_count], -1);
do_update(precommit_fail) ->
    exometer:update([?PFX, ?APP, precommit_fail], 1);
do_update(postcommit_fail) ->
    exometer:update([?PFX, ?APP, postcommit_fail], 1);
do_update({fsm_spawned, Type}) when Type =:= gets; Type =:= puts ->
    exometer:update([?PFX, ?APP, node, Type, fsm, active], 1);
do_update({fsm_exit, Type}) when Type =:= gets; Type =:= puts  ->
    exometer:update([?PFX, ?APP, node, Type, fsm, active], -1);
do_update({fsm_error, Type}) when Type =:= gets; Type =:= puts ->
    ok = do_update({fsm_exit, Type}),
    exometer:update([?PFX, ?APP, node, Type, fsm, errors], 1);
do_update({index_create, Pid}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, index, fsm, create], 1),
    ok = exometer:update([P, ?APP, index, fsm, active], 1),
    add_monitor(index, Pid),
    ok;
do_update(index_create_error) ->
    exometer:update([?PFX, ?APP, index, fsm, create, error], 1);
do_update({list_create, Pid}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, list, fsm, create], 1),
    ok = exometer:update([P, ?APP, list, fsm, active], 1),
    add_monitor(list, Pid),
    ok;
do_update(list_create_error) ->
    exometer:update([?PFX, ?APP, list, fsm, create, error], 1);
do_update({fsm_destroy, Type}) ->
    exometer:update([?PFX, ?APP, Type, fsm, active], -1);
do_update({Type, actor_count, Count}) ->
    exometer:update([?PFX, ?APP, Type, actor_count], Count);
do_update(late_put_fsm_coordinator_ack) ->
    exometer:update([?PFX, ?APP, late_put_fsm_coordinator_ack], 1);
do_update({consistent_get, _Bucket, Microsecs, ObjSize}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, consistent, gets], 1),
    ok = exometer:update([P, ?APP, consistent, gets, time], Microsecs),
    create_or_update([P, ?APP, consistent, gets, objsize], ObjSize, histogram);
do_update({consistent_put, _Bucket, Microsecs, ObjSize}) ->
    P = ?PFX,
    ok = exometer:update([P, ?APP, consistent, puts], 1),
    ok = exometer:update([P, ?APP, consistent, puts, time], Microsecs),
    create_or_update([P, ?APP, consistent, puts, objsize], ObjSize, histogram).


%% private

add_monitor(Type, Pid) ->
    gen_server:cast(?SERVER, {monitor, Type, Pid}).

monitor_loop(Type) ->
    receive
        {add_pid, Pid} ->
            erlang:monitor(process, Pid);
        {'DOWN', _Ref, process, _Pid, _Reason} ->
            do_update({fsm_destroy, Type})
    end,
    monitor_loop(Type).

%% Per index stats (by op)
do_per_index(Op, Idx, USecs) ->
    IdxAtom = list_to_atom(integer_to_list(Idx)),
    P = riak_core_stat:prefix(),
    create_or_update([P, ?APP, vnode, Op, IdxAtom], 1, spiral),
    create_or_update([P, ?APP, vnode, Op, time, IdxAtom], USecs, histogram).

%%  per bucket get_fsm stats
do_get_bucket(false, _) ->
    ok;
do_get_bucket(true, {Bucket, Microsecs, Stages, NumSiblings, ObjSize}=Args) ->
    P = riak_core_stat:prefix(),
    case exometer:update([P, ?APP, node, gets, Bucket], 1) of
        ok ->
            [exometer:update([P, ?APP, node, gets, Dimension, Bucket], Arg)
             || {Dimension, Arg} <- [{time, Microsecs},
                                     {siblings, NumSiblings},
                                     {objsize, ObjSize}], Arg /= undefined],
            do_stages([P, ?APP, node, gets, time, Bucket], Stages);
        {error, not_found} ->
            exometer:new([P, ?APP, node, gets, Bucket], spiral),
            [register_stat([P, ?APP, node, gets, Dimension, Bucket], histogram) || Dimension <- [time,
                                                                                                 siblings,
                                                                                                 objsize]],
            do_get_bucket(true, Args)
    end;
do_get_bucket(true, {Bucket, Microsecs, Stages, NumSiblings, ObjSize, Type}=Args) ->
    P = riak_core_stat:prefix(),
    case exometer:update([P, ?APP, node, gets, Type, Bucket], 1) of
	ok ->
	    [exometer:update([P, ?APP, node, gets, Dimension, Bucket], Arg)
	     || {Dimension, Arg} <- [{time, Microsecs},
				     {siblings, NumSiblings},
				     {objsize, ObjSize}], Arg /= undefined],
	    do_stages([P, ?APP, node, gets, Type, time, Bucket], Stages);
	{error, not_found} ->
	    exometer:new([P, ?APP, node, gets, Type, Bucket], spiral),
	    [register_stat([P, ?APP, node, gets, Type, Dimension, Bucket], histogram)
	     || Dimension <- [time, siblings, objsize]],
	    do_get_bucket(true, Args)
    end.

%% per bucket put_fsm stats
do_put_bucket(false, _) ->
    ok;
do_put_bucket(true, {Bucket, Microsecs, Stages}=Args) ->
    P = riak_core_stat:prefix(),
    case exometer:update([P, ?APP, node, puts, Bucket], 1) of
        ok ->
            exometer:update([P, ?APP, node, puts, time, Bucket], Microsecs),
            do_stages([P, ?APP, node, puts, time, Bucket], Stages);
        {error, _} ->
            register_stat([P, ?APP, node, puts, Bucket], spiral),
            register_stat([P, ?APP, node, puts, time, Bucket], histogram),
            do_put_bucket(true, Args)
    end;
do_put_bucket(true, {Bucket, Microsecs, Stages, Type}=Args) ->
    P = riak_core_stat:prefix(),
    case exometer:update([P, ?APP, node, puts, Type, Bucket], 1) of
	ok ->
	    exometer:update([P, ?APP, node, puts, Type, time, Bucket], Microsecs),
	    do_stages([P, ?APP, node, puts, Type, time, Bucket], Stages);
	{error, not_found} ->
	    register_stat([P, ?APP, node, puts, Type, Bucket], spiral),
	    register_stat([P, ?APP, node, puts, Type, time, Bucket], histogram),
	    do_put_bucket(true, Args)
    end.


%% Path is list that provides a conceptual path to a stat
%% folsom uses the tuple as flat name
%% but some ets query magic means we can get stats by APP, Stat, DimensionX
%% Path, then is a list like [?APP, StatName]
%% Both get and put fsm have a list of {state, microseconds}
%% that they provide for stats.
%% Use the state to append to the stat "path" to create a further dimension on the stat
do_stages(_Path, []) ->
    ok;
do_stages(Path, [{Stage, Time}|Stages]) ->
    create_or_update(Path ++ [Stage], Time, histogram),
    do_stages(Path, Stages).

%% create dimensioned stats for read repairs.
%% The indexes are from get core [{Index, Reason::notfound|outofdate}]
%% preflist is a preflist of [{{Index, Node}, Type::primary|fallback}]
do_repairs(Indices, Preflist) ->
    Pfx = riak_core_stat:prefix(),
    lists:foreach(fun({{Idx, Node}, Type}) ->
                          case proplists:get_value(Idx, Indices) of
                              undefined ->
                                  ok;
                              Reason ->
                                  create_or_update([Pfx, ?APP, node, gets, read_repairs, Node, Type, Reason], 1, spiral)
                          end
                  end,
                  Preflist).

%% for dynamically created / dimensioned stats
%% that can't be registered at start up
create_or_update(Name, UpdateVal, Type) ->
    exometer:update_or_create(Name, UpdateVal, Type, []).

report_legacy() ->
    riak_kv_wm_stats:legacy_report_map().

%% @doc list of {Name, Type} for static
%% stats that we can register at start up
stats() ->
    Pfx = riak_core_stat:prefix(),
    [{[vnode, gets], spiral},
     {[vnode, gets, time], histogram},
     {[vnode, puts], spiral},
     {[vnode, puts, time], histogram},
     {[vnode, index, refreshes], spiral},
     {[vnode, index, reads], spiral},
     {[vnode, index ,writes], spiral},
     {[vnode, index, writes, postings], spiral},
     {[vnode, index, deletes], spiral},
     {[vnode, index, deletes, postings], spiral},
     {[vnode, counter, update], spiral},
     {[vnode, counter, update, time], histogram},
     {[vnode, set, update], spiral},
     {[vnode, set, update, time], histogram},
     {[vnode, map, update], spiral},
     {[vnode, map, update, time], histogram},
     {[node, gets], spiral},
     {[node, gets, fsm, active], counter},
     {[node, gets, fsm, errors], spiral},
     {[node, gets, objsize], histogram},
     {[node, gets, read_repairs], spiral},
     {[node, gets, skipped_read_repairs], spiral},
     {[node, gets, siblings], histogram},
     {[node, gets, time], histogram},
     {[node, gets, counter], spiral},
     {[node, gets, counter, objsize], histogram},
     {[node, gets, counter, read_repairs], spiral},
     {[node, gets, counter, siblings], histogram},
     {[node, gets, counter, time], histogram},
     {[node, gets, set], spiral},
     {[node, gets, set, objsize], histogram},
     {[node, gets, set, read_repairs], spiral},
     {[node, gets, set, siblings], histogram},
     {[node, gets, set, time], histogram},
     {[node, gets, map], spiral},
     {[node, gets, map, objsize], histogram},
     {[node, gets, map, read_repairs], spiral},
     {[node, gets, map, siblings], histogram},
     {[node, gets, map, time], histogram},
     {[node, puts], spiral},
     {[node, puts, coord_redirs], counter},
     {[node, puts, fsm, active], counter},
     {[node, puts, fsm, errors], spiral},
     {[node, puts, time], histogram},
     {[node, puts, counter], spiral},
     {[node, puts, counter, time], histogram},
     {[node, puts, set], spiral},
     {[node, puts, set, time], histogram},
     {[node, puts, map], spiral},
     {[node, puts, map, time], histogram},
     {[index, fsm, create], spiral},
     {[index, fsm, create, error], spiral},
     {[index, fsm, active], counter},
     {[list, fsm, create], spiral},
     {[list, fsm, create, error], spiral},
     {[list, fsm, active], counter},
     {mapper_count, counter},
     {precommit_fail, counter},
     {postcommit_fail, counter},
     {[vnode, backend, leveldb, read_block_error],
      {function, ?MODULE, leveldb_read_block_errors, [], match, value}},
     {[counter, actor_count], histogram},
     {[set, actor_count], histogram},
     {[map, actor_count], histogram},
     {[object, merge], spiral},
     {[object, merge, time], histogram},
     {[object, counter, merge], spiral},
     {[object, counter, merge, time], histogram},
     {[object, set, merge], spiral},
     {[object, set, merge, time], histogram},
     {[object, map, merge], spiral},
     {[object, map, merge, time], histogram},
     {late_put_fsm_coordinator_ack, counter},
     {[consistent, gets], spiral},
     {[consistent, gets, time], histogram},
     {[consistent, gets, objsize], histogram},
     {[consistent, puts], spiral},
     {[consistent, puts, time], histogram},
     {[consistent, puts, objsize], histogram},
     {[storage_backend], {function, app_helper, get_env, [riak_kv, storage_backend], match, value}},
     {[ring_stats], {function, riak_kv_stat_bc, ring_stats, [], proplist, [ring_members,
									   ring_num_partitions,
									   ring_ownership]}}
     | read_repair_aggr_stats(Pfx)].

read_repair_aggr_stats(Pfx) ->
    [{[read_repairs,Type,Reason],
      {function,exometer,aggregate,
       [ [{{[Pfx,?APP,node,gets,read_repairs,'_',Type,Reason],'_','_'},
	   [], [true]}], [one,count] ], value, [one,count]}}
     || Type <- [primary, fallback],
	Reason <- [notfound, outofdate]
    ].


do_register_stat(Name, Type) ->
    exometer:new(Name, Type).

%% @doc produce the legacy blob of stats for display.
produce_stats() ->
    riak_kv_stat_bc:produce_stats().

%% @doc get the leveldb.ReadBlockErrors counter.
%% non-zero values mean it is time to consider replacing
%% this nodes disk.
leveldb_read_block_errors() ->
    %% level stats are per node
    %% but the way to get them is
    %% is with riak_kv_vnode:vnode_status/1
    %% for that reason just chose a partition
    %% on this node at random
    %% and ask for it's stats
    {ok, R} = riak_core_ring_manager:get_my_ring(),
    case riak_core_ring:my_indices(R) of
        [] -> undefined;
        [Idx] ->
            Status = vnode_status(Idx),
            leveldb_read_block_errors(Status);
        Indices ->
            %% technically a call to status is a vnode
            %% operation, so spread the load by picking
            %% a vnode at random.
            Nth = crypto:rand_uniform(1, length(Indices)),
            Idx = lists:nth(Nth, Indices),
            Status = vnode_status(Idx),
            leveldb_read_block_errors(Status)
    end.

vnode_status(Idx) ->
    PList = [{Idx, node()}],
    [{Idx, Status}] = riak_kv_vnode:vnode_status(PList),
    case lists:keyfind(backend_status, 1, Status) of
        false ->
            %% if for some reason backend_status is absent from the
            %% status list
            {error, no_backend_status};
        BEStatus ->
            BEStatus
    end.

leveldb_read_block_errors({backend_status, riak_kv_eleveldb_backend, Status}) ->
    rbe_val(proplists:get_value(read_block_error, Status));
leveldb_read_block_errors({backend_status, riak_kv_multi_backend, Statuses}) ->
    multibackend_read_block_errors(Statuses, undefined);
leveldb_read_block_errors({error, Reason}) ->
    {error, Reason};
leveldb_read_block_errors(_) ->
    undefined.

multibackend_read_block_errors([], Val) ->
    rbe_val(Val);
multibackend_read_block_errors([{_Name, Status}|Rest], undefined) ->
    RBEVal = case proplists:get_value(mod, Status) of
                 riak_kv_eleveldb_backend ->
                     proplists:get_value(read_block_error, Status);
                 _ -> undefined
             end,
    multibackend_read_block_errors(Rest, RBEVal);
multibackend_read_block_errors(_, Val) ->
    rbe_val(Val).

rbe_val(Bin) when is_binary(Bin) ->
    list_to_integer(binary_to_list(Bin));
rbe_val(_) ->
    undefined.

%% All stat creation is serialized through riak_kv_stat.
%% Some stats are created on demand as part of the call to `update/1'.
%% When a stat error is caught, the stat must be deleted and recreated.
%% Since stat updates can happen from many processes concurrently
%% a stat that throws an error may already have been deleted and
%% recreated. To protect against needlessly deleting and recreating
%% an already 'fixed stat' first retry the stat update. There is a chance
%% that the retry succeeds as the stat has been recreated, but some on
%% demand stat it uses has not yet. Since stat creates are serialized
%% in riak_kv_stat re-registering a stat could cause a deadlock.
%% This loop is spawned as a process to avoid that.
stat_repair_loop() ->
    receive
        {'DOWN', _, process, _, _} ->
            ok;
        _ ->
            stat_repair_loop()
    end.

stat_repair_loop(Dad) ->
    erlang:monitor(process, Dad),
    stat_repair_loop().

-ifdef(TEST).
-define(LEVEL_STATUS(Idx, Val),  [{Idx, [{backend_status, riak_kv_eleveldb_backend,
                                          [{read_block_error, Val}]}]}]).
-define(BITCASK_STATUS(Idx),  [{Idx, [{backend_status, riak_kv_bitcask_backend,
                                       []}]}]).
-define(MULTI_STATUS(Idx, Val), [{Idx,  [{backend_status, riak_kv_multi_backend, Val}]}]).

leveldb_rbe_test_() ->
    {foreach,
     fun() ->
	     exometer:start(),
             meck:new(riak_core_ring_manager),
             meck:new(riak_core_ring),
             meck:new(riak_kv_vnode),
             meck:expect(riak_core_ring_manager, get_my_ring, fun() -> {ok, [fake_ring]} end)
     end,
     fun(_) ->
	     exometer:stop(),
             meck:unload(riak_kv_vnode),
             meck:unload(riak_core_ring),
             meck:unload(riak_core_ring_manager)
     end,
     [{"Zero indexes", fun zero_indexes/0},
      {"Single index", fun single_index/0},
      {"Multi indexes", fun multi_index/0},
      {"Bitcask Backend", fun bitcask_backend/0},
      {"Multi Backend", fun multi_backend/0}]
    }.

start_exometer_test_env() ->
    ok = exometer:start(),
    ok = meck:new(riak_core_ring_manager),
    ok = meck:new(riak_core_ring),
    ok = meck:new(riak_kv_vnode),
    ok = meck:expect(riak_core_stat, vnodeq_stats, fun() -> [] end),
    meck:expect(riak_core_ring_manager, get_my_ring, fun() -> {ok, [fake_ring]} end).

stop_exometer_test_env() ->
    ok = exometer:stop(),
    ok = meck:unload(riak_kv_vnode),
    ok = meck:unload(riak_core_ring),
    meck:unload(riak_core_ring_manager).

create_or_update_histogram_test() ->
    ok = start_exometer_test_env(),

    Metric = [riak_kv,put_fsm,counter,time],
    ok = repeat_create_or_update(Metric, 1, histogram, 100),
    ?assertNotEqual(exometer:get_value(Metric), 0),
    Stats = get_stats(),
    %%lager:info("stats prop list ~s", [Stats]),
    ?assertNotEqual(proplists:get_value({node_put_fsm_counter_time_mean}, Stats), 0),

    ok = stop_exometer_test_env().

repeat_create_or_update(Name, UpdateVal, Type, Times) when Times > 0 ->
    repeat_create_or_update(Name, UpdateVal, Type, Times, 0).
repeat_create_or_update(Name, UpdateVal, Type, Times, Ops) when Ops < Times ->
    ok = create_or_update(Name, UpdateVal, Type),
    repeat_create_or_update(Name, UpdateVal, Type, Times, Ops + 1);
repeat_create_or_update(_Name, _UpdateVal, _Type, Times, Ops) when Ops >= Times ->
    ok.

zero_indexes() ->
    meck:expect(riak_core_ring, my_indices, fun(_R) -> [] end),
    ?assertEqual(undefined, leveldb_read_block_errors()).

single_index() ->
    meck:expect(riak_core_ring, my_indices, fun(_R) -> [index1] end),
    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) -> ?LEVEL_STATUS(Idx, <<"100">>) end),
    ?assertEqual(100, leveldb_read_block_errors()),

    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) -> ?LEVEL_STATUS(Idx, nonsense) end),
    ?assertEqual(undefined, leveldb_read_block_errors()).

multi_index() ->
    meck:expect(riak_core_ring, my_indices, fun(_R) -> [index1, index2, index3] end),
    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) -> ?LEVEL_STATUS(Idx, <<"100">>) end),
    ?assertEqual(100, leveldb_read_block_errors()).

bitcask_backend() ->
    meck:expect(riak_core_ring, my_indices, fun(_R) -> [index1, index2, index3] end),
    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) -> ?BITCASK_STATUS(Idx) end),
    ?assertEqual(undefined, leveldb_read_block_errors()).

multi_backend() ->
    meck:expect(riak_core_ring, my_indices, fun(_R) -> [index1, index2, index3] end),
    %% some backends, none level
    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) ->
                                                     ?MULTI_STATUS(Idx,
                                                                   [{name1, [{mod, bitcask}]},
                                                                    {name2, [{mod, fired_chicked}]}]
                                                                  )
                                             end),
    ?assertEqual(undefined, leveldb_read_block_errors()),

    %% one or movel leveldb backends (first level answer is returned)
    meck:expect(riak_kv_vnode, vnode_status, fun([{Idx, _}]) ->
                                                     ?MULTI_STATUS(Idx,
                                                                   [{name1, [{mod, bitcask}]},
                                                                    {name2, [{mod, riak_kv_eleveldb_backend},
                                                                             {read_block_error, <<"99">>}]},
                                                                    {name2, [{mod, riak_kv_eleveldb_backend},
                                                                             {read_block_error, <<"1000">>}]}]
                                                                  )
                                             end),
    ?assertEqual(99, leveldb_read_block_errors()).

-endif.
