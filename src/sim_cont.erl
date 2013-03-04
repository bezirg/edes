-module(sim_cont).

%% API exports
%% 
-export([
         start/3, start/4,
         start_link/3, start_link/4,
         format_status/2
         ]).


%% System exports
%% 
-export([
         init_it/6,
         system_continue/3,
         system_terminate/4,
         system_code_change/4
        ]).


%% Types and Callbacks
%% 
-type lp_spec() :: {'local', Name :: atom(), Module :: module()} 
                 | {'remote', Node :: node(), Name :: atom(), Module :: module()}.

-callback init(Args :: term()) ->
    {ok, [lp_spec()]}
    | ignore.


%% API
%% 
%% @doc Callback, not documented
start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).
%% @doc Callback, not documented
start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).
%% @doc Callback, not documented
start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).
%% @doc Callback, not documented
start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).
%% @doc Callback, not documented
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [Name, State, Mod, _Time]] = StatusData,
    Header = gen:format_status_header("Status for simulation controller",
                                      Name),
    Log = sys:get_debug(log, Debug, []),
    DefaultStatus = [{data, [{"State", State}]}],
    Specfic =
	case erlang:function_exported(Mod, format_status, 2) of
	    true ->
		case catch Mod:format_status(Opt, [PDict, State]) of
		    {'EXIT', _} -> DefaultStatus;
                    StatusList when is_list(StatusList) -> StatusList;
		    Else -> [Else]
		end;
	    _ ->
		DefaultStatus
	end,
    [{header, Header},
     {data, [{"Status", SysState},
	     {"Parent", Parent},
	     {"Logged events", Log}]} |
     Specfic].


%% System functions
%% 
%% @doc Callback, not documented
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = name(Name0),
    Debug = debug_options(Name, Options),
    case catch Mod:init(Args) of
	{ok, LPSpecs} ->
        spawnLPs(LPSpecs),
        syncLPs(LPSpecs),
	    proc_lib:init_ack(Starter, {ok, self()}),
	    loop(Parent, Name, LPSpecs, Mod, infinity, Debug);
	ignore ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, ignore),
	    exit(normal);
	{'EXIT', Reason} ->
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	Else ->
	    Error = {bad_return_value, Else},
	    proc_lib:init_ack(Starter, {error, Error}),
	    exit(Error)
    end.
%% @doc Callback, not documented
system_continue(Parent, Debug, [Name, State, Mod, Time]) ->
    loop(Parent, Name, State, Mod, Time, Debug).

-spec system_terminate(_, _, _, [_]) -> no_return().
%% @doc Callback, not documented
system_terminate(Reason, _Parent, Debug, [Name, State, Mod, _Time]) ->
    terminate(Reason, Name, [], Mod, State, Debug).
%% @doc Callback, not documented
system_code_change([Name, State, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
	{ok, NewState} -> {ok, [Name, NewState, Mod, Time]};
	Else -> Else
    end.

%% Internal functions
%% 

%% @doc Internal, Main loop of the Simulation Controller. Does not do anything.
loop(Parent, Name, State, Mod, Timeout, Debug) ->
    ok.

%% @doc Internal, for each LP specification, spawns/starts the OTP sim_proc behaviour process.
%% @todo starting global LPs
-spec spawnLPs([lp_spec()]) -> ok.
spawnLPs(LPSpecs) ->
    %% spawn sim_proc behaviour process for each logical process
    lists:foreach(fun ({local, Name, Module}) -> 
                          sim_proc:start({local, Name}, Module, [], [{debug, [trace]}])
                  end, LPSpecs).

%% @doc Syncs together LPs upon initialization, so to make sure the LPs warmed up.
%% @todo syncing global LPs
-spec syncLPs([lp_spec()]) -> ok.
syncLPs(LPSpecs) ->
    %% initialize synchronization by broadcasting sync messages to sim_procs
    syncLPs(LPSpecs, length(LPSpecs)).

%% @doc Syncs together LPs upon initialization, so to make sure the LPs warmed up.
syncLPs([], 0) ->
    ok;
syncLPs([], N) -> 
    %% synchronization reply of the sim_proc processes
    %% to ensure that the sim_proc processes have warmed up
    receive
        ok -> syncLPs([], N-1)
    end;
syncLPs([{local, Name, _} | Rest], N) ->
    Name ! {controller_sync, self()},
    syncLPs(Rest, N).

%% @doc Internal, calls Mod:terminate, exits Simulation controller process.
terminate(Reason, Name, Msg, Mod, State, Debug) ->
    case catch Mod:terminate(Reason, State) of
	{'EXIT', R} ->
	    error_info(R, Name, Msg, State, Debug),
	    exit(R);
	_ ->
	    case Reason of
            normal ->
                exit(normal);
            timeout ->
                exit(timeout);
            shutdown ->
                exit(shutdown);
            {shutdown,_}=Shutdown ->
                exit(Shutdown);
		_ ->
		    FmtState =
			case erlang:function_exported(Mod, format_status, 2) of
			    true ->
				Args = [get(), State],
				case catch Mod:format_status(terminate, Args) of
				    {'EXIT', _} -> State;
				    Else -> Else
				end;
			    _ ->
				State
			end,
		    error_info(Reason, Name, Msg, FmtState, Debug),
		    exit(Reason)
	    end
    end.


%% @doc Internal, Debugging printing; used by the terminate function.
error_info(_Reason, application_controller, _Msg, _State, _Debug) ->
    ok;
error_info(Reason, Name, Msg, State, Debug) ->
    Reason1 = 
	case Reason of
	    {undef,[{M,F,A,L}|MFAs]} ->
		case code:is_loaded(M) of
		    false ->
			{'module could not be loaded',[{M,F,A,L}|MFAs]};
		    _ ->
			case erlang:function_exported(M, F, length(A)) of
			    true ->
				Reason;
			    false ->
				{'function not exported',[{M,F,A,L}|MFAs]}
			end
		end;
	    _ ->
		Reason
	end,    
    error_logger:format("** Simulation controller ~p terminating \n"
           "** Last message in was ~p~n"
           "** When Server state == ~p~n"
           "** Reason for termination == ~n** ~p~n",
	   [Name, Msg, State, Reason1]),
    sys:print_log(Debug),
    ok.

%% @doc Internal, Debugging printing , debug flag must be enabled upon start ({debug, trace | log | ...})
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg ~p~n", [Name, Event]).


%% Misc functions
%% 

%% @doc Misc, not documented
name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

%% @doc Misc, not documented
unregister_name({local,Name}) ->
    _ = (catch unregister(Name));
unregister_name({global,Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.
    
%% @doc Misc, not documented
opt(Op, [{Op, Value}|_]) ->
    {ok, Value};
opt(Op, [_|Options]) ->
    opt(Op, Options);
opt(_, []) ->
    false.

%% @doc Misc, not documented
debug_options(Name, Opts) ->
    case opt(debug, Opts) of
	{ok, Options} -> dbg_options(Name, Options);
	_ -> dbg_options(Name, [])
    end.

%% @doc Misc, not documented
dbg_options(Name, []) ->
    Opts = 
	case init:get_argument(generic_debug) of
	    error ->
		[];
	    _ ->
		[log, statistics]
	end,
    dbg_opts(Name, Opts);
%% @doc Misc, not documented
dbg_options(Name, Opts) ->
    dbg_opts(Name, Opts).
%% @doc Misc, not documented
dbg_opts(Name, Opts) ->
    case catch sys:debug_options(Opts) of
	{'EXIT',_} ->
	    error_logger:format("~p: ignoring erroneous debug options - ~p~n",
		   [Name, Opts]),
	    [];
	Dbg ->
	    Dbg
    end.
