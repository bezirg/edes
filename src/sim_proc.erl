-module(sim_proc).

%% API
-export([start/3, start/4,
	 start_link/3, start_link/4,
     schedule/2, schedule/3, get_clock/0, print/1, print/2, println/1, println/2,
     link_from/1, link_to/2,
	 enter_loop/3, enter_loop/4, enter_loop/5]).

%% System exports
-export([system_continue/3,
	 system_terminate/4,
	 system_code_change/4,
	 format_status/2]).

%% Internal exports
-export([init_it/6]).

-import(error_logger, [format/2]).

%%%=========================================================================
%%%  API
%%%=========================================================================

-callback init(Args :: term()) ->
    {ok, State :: term()} | {ok, State :: term(), timeout()} |
    {stop, Reason :: term()} | ignore.
-callback handle_event(Event :: term(), State :: term()) ->
    {ok, NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: timeout() | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: term()) ->
    term().
-callback code_change(OldVsn :: (term() | {down, term()}), State :: term(),
                      Extra :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

%%%  -----------------------------------------------------------------
%%% Starts a generic server.
%%% start(Mod, Args, Options)
%%% start(Name, Mod, Args, Options)
%%% start_link(Mod, Args, Options)
%%% start_link(Name, Mod, Args, Options) where:
%%%    Name ::= {local, atom()} | {global, atom()} | {via, atom(), term()}
%%%    Mod  ::= atom(), callback module implementing the 'real' server
%%%    Args ::= term(), init arguments (to Mod:init/1)
%%%    Options ::= [{timeout, Timeout} | {debug, [Flag]}]
%%%      Flag ::= trace | log | {logfile, File} | statistics | debug
%%%          (debug == log && statistics)
%%% Returns: {ok, Pid} |
%%%          {error, {already_started, Pid}} |
%%%          {error, Reason}
%%% -----------------------------------------------------------------
start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).

start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).

start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).


%%-----------------------------------------------------------------
%% enter_loop(Mod, Options, State, <ServerName>, <TimeOut>) ->_ 
%%   
%% Description: Makes an existing process into a gen_server. 
%%              The calling process will enter the gen_server receive 
%%              loop and become a gen_server process.
%%              The process *must* have been started using one of the 
%%              start functions in proc_lib, see proc_lib(3). 
%%              The user is responsible for any initialization of the 
%%              process, including registering a name for it.
%%-----------------------------------------------------------------
enter_loop(Mod, Options, State) ->
    enter_loop(Mod, Options, State, self(), infinity).

enter_loop(Mod, Options, State, ServerName = {Scope, _})
  when Scope == local; Scope == global ->
    enter_loop(Mod, Options, State, ServerName, infinity);

enter_loop(Mod, Options, State, ServerName = {via, _, _}) ->
    enter_loop(Mod, Options, State, ServerName, infinity);

enter_loop(Mod, Options, State, Timeout) ->
    enter_loop(Mod, Options, State, self(), Timeout).

enter_loop(Mod, Options, State, ServerName, Timeout) ->
    Name = get_proc_name(ServerName),
    Parent = get_parent(),
    Debug = debug_options(Name, Options),
    loop(Parent, Name, State, Mod, Timeout, Debug).

%%%========================================================================
%%% Gen-callback functions
%%%========================================================================

%%% ---------------------------------------------------
%%% Initiate the new process.
%%% Register the name using the Rfunc function
%%% Calls the Mod:init/Args function.
%%% Finally an acknowledge is sent to Parent and the main
%%% loop is entered.
%%% ---------------------------------------------------
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    Name = name(Name0),
    Debug = debug_options(Name, Options),
    put(debug, Debug),
    put(name, Name),
    put(clock, 0),
    put(queues, sets:new()),
    put(local,[]),
    put(lookahead, []),
    case catch Mod:init(Args) of
	{ok, State} ->
	    proc_lib:init_ack(Starter, {ok, self()}),
        wait_controller(),
	    loop(Parent, Name, State, Mod, infinity, Debug);
	{ok, State, Timeout} ->
	    proc_lib:init_ack(Starter, {ok, self()}), 	    
        wait_controller(),
	    loop(Parent, Name, State, Mod, Timeout, Debug);
	{stop, Reason} ->
	    %% For consistency, we must make sure that the
	    %% registered name (if any) is unregistered before
	    %% the parent process is notified about the failure.
	    %% (Otherwise, the parent process could get
	    %% an 'already_started' error if it immediately
	    %% tried starting the process again.)
	    unregister_name(Name0),
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
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

name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

unregister_name({local,Name}) ->
    _ = (catch unregister(Name));
unregister_name({global,Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.
    
wait_controller() ->
    receive
        {controller_sync, Controller} ->  send_neighbours(0), % initiate lookahead
                                          Controller ! ok
    end.
            


%%%========================================================================
%%% Internal functions
%%%========================================================================
%%% ---------------------------------------------------
%%% The MAIN loop.
%%% ---------------------------------------------------
loop(Parent, Name, State, Mod, Timeout, Debug) ->
    wait_queues(),
    {EventTime, Event} = remove_smallest_timestamp(),
    %% Unsorted_event_list = get(local),
    %% case Unsorted_event_list of
    %%     [] -> terminate(normal, Name, [], Mod, State, Debug);
    %%     _ -> ok
    %% end,
    Next_clock = EventTime,
    Clock = get(clock),
    case Next_clock < Clock of
        true -> exit({engine_error, Next_clock, queue:to_list(get(hd(sets:to_list(get(queues)))))});
        false ->
            case Next_clock > Timeout of
                true -> put(clock, Timeout),
                        terminate(timeout, Name, [], Mod, State, Debug);
                false -> put(clock, Next_clock),
                         send_neighbours(Next_clock),
                         case Event == null of
                             true -> % is a null message
                                     loop(Parent, Name, State, Mod, Timeout, Debug);
                             false -> Res = Mod:handle_event(Event, State),
                                      case Debug =:= [] of
                                          true -> handle_res(Res, Next_clock, Parent, Name, State, Mod, Timeout);
                                          false -> handle_res(Res, Next_clock, Parent, Name, State, Mod, Timeout, Debug)
                                      end
                         end
            end
    end.

wait_queues() ->
    receive
        %% {add_link, From} -> put(queues, sets:add_element(From, get(queues))),
        %%                     put(From, queue:new());
        {remove_link, From} -> put(queues, sets:del_element(From, get(queues))),
                               %% move to local
                               put(local, get(local) ++ queue:to_list(get(From))),
                               erase(From);
        {schedule, From, Event, Time} ->  put(From, queue:in({Time, Event}, get(From)))
    end,
    case lists:any(fun (Q) -> queue:is_empty(get(Q)) end, sets:to_list(get(queues))) of % can be optimized with a sets:fold
        true -> wait_queues();
        false -> ok
    end.
        
remove_smallest_timestamp() ->
    % can be optimized with a sets:fold 
    SmallestQueue = lists:foldl(fun (Q,Acc) -> min({queue:get(get(Q)), Q}, Acc) end, {{infinity, undefined}, undefined}, sets:to_list(get(queues))), 
    {RemoteEvent, Queue} = SmallestQueue,
    %% sort local
    {LocalEvent, Rest_local} = case lists:sort(get(local)) of
                                   [L | Ls] -> {L, Ls};
                                   [] -> {{infinity, undefined}, []} % local is empty
                               end,
    case RemoteEvent < LocalEvent of
        true -> put(Queue, queue:drop(get(Queue))),
                 io:format("~p Local: ~p  , Remote ~p", [get(name), LocalEvent, RemoteEvent]),
                RemoteEvent;
        false -> put(local, Rest_local),
                 io:format("~p Local: ~p  , Remote ~p", [get(name), LocalEvent, RemoteEvent]),
                 LocalEvent
    end.


handle_res(Res, Clock, Parent, Name, State, Mod, Timeout) ->
    case Res of
        {ok, NState} ->
            loop(Parent, Name, NState, Mod, Timeout, []);
        {ok, NState, Time1} ->
            loop(Parent, Name, NState, Mod, Clock + Time1, []);
        {stop, Reason, NState} ->
            terminate(Reason, Name, Res, Mod, NState, []);
        _ ->
            terminate({bad_return_value, Res}, Name, Res, Mod, State, [])
    end.

handle_res(Res, Clock, Parent, Name, State, Mod, Timeout, Debug) ->
    case Res of
	{ok, NState} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {ok, NState}),
	    loop(Parent, Name, NState, Mod, Timeout, Debug1);
	{ok, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
				      {ok, NState}),
	    loop(Parent, Name, NState, Mod, Clock + Time1, Debug1);
 	{stop, Reason, NState} ->
	    terminate(Reason, Name, Res, Mod, NState, Debug);
	_ ->
	    terminate({bad_return_value, Res}, Name, Res, Mod, State, Debug)
    end.


send_neighbours(Clock) ->
    %% schedules null messages to the LPs with the lookahead
    lists:foreach(fun ({LP, Lookahead}) -> LP ! {schedule, get(name), null, Clock + Lookahead} end, get(lookahead)),
    case get(debug) of
        [] -> ok;
        Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {null, Clock})
    end.


                          

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(Parent, Debug, [Name, State, Mod, Time]) ->
    loop(Parent, Name, State, Mod, Time, Debug).

-spec system_terminate(_, _, _, [_]) -> no_return().

system_terminate(Reason, _Parent, Debug, [Name, State, Mod, _Time]) ->
    terminate(Reason, Name, [], Mod, State, Debug).

system_code_change([Name, State, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
	{ok, NewState} -> {ok, [Name, NewState, Mod, Time]};
	Else -> Else
    end.

%%-----------------------------------------------------------------
%% Format debug messages.  Print them as the call-back module sees
%% them, not as the real erlang messages.  Use trace for that.
%%-----------------------------------------------------------------
print_event(Dev, {in, Msg}, Name) ->
    case Msg of
	{'$gen_call', {From, _Tag}, Call} ->
	    io:format(Dev, "*DBG* ~p got call ~p from ~w~n",
		      [Name, Call, From]);
	{'$gen_cast', Cast} ->
	    io:format(Dev, "*DBG* ~p got cast ~p~n",
		      [Name, Cast]);
	_ ->
	    io:format(Dev, "*DBG* ~p got ~p~n", [Name, Msg])
    end;
print_event(Dev, {out, Msg, To, State}, Name) ->
    io:format(Dev, "*DBG* ~p sent ~p to ~w, new state ~w~n", 
	      [Name, Msg, To, State]);
print_event(Dev, {ok, State}, Name) ->
    io:format(Dev, "*DBG* ~p new state ~w~n", [Name, State]);
print_event(Dev, {schedule, Event, Time}, Name) ->
    io:format(Dev, "*DBG* ~p scheduled ~w in ~p ~n", [Name, Event, Time]);
print_event(Dev, {null, Clock}, Name ) ->
    io:format(Dev, "*DBG* ~p@~p null ~n", [Clock, Name]);
print_event(Dev, {unschedule, Event}, Name) ->
    io:format(Dev, "*DBG* ~p unscheduled ~w ~n", [Name, Event]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).


%%% ---------------------------------------------------
%%% Terminate the server.
%%% ---------------------------------------------------

terminate(Reason, Name, Msg, Mod, State, Debug) ->
    remove_links(),
    case catch Mod:terminate(Reason, State) of
	{'EXIT', R} ->
	    error_info(R, Name, Msg, State, Debug),
	    exit(R);
	_ ->
	    case Reason of
		normal ->
		    exit(normal);
        timeout ->
            exit(normal);                       % otp considers non-normal,shutdown as crashes
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

error_info(_Reason, application_controller, _Msg, _State, _Debug) ->
    %% OTP-5811 Don't send an error report if it's the system process
    %% application_controller which is terminating - let init take care
    %% of it instead
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
    format("** Generic server ~p terminating \n"
           "** Last message in was ~p~n"
           "** When Server state == ~p~n"
           "** Reason for termination == ~n** ~p~n",
	   [Name, Msg, State, Reason1]),
    sys:print_log(Debug),
    ok.

%%% ---------------------------------------------------
%%% Misc. functions.
%%% ---------------------------------------------------

opt(Op, [{Op, Value}|_]) ->
    {ok, Value};
opt(Op, [_|Options]) ->
    opt(Op, Options);
opt(_, []) ->
    false.

debug_options(Name, Opts) ->
    case opt(debug, Opts) of
	{ok, Options} -> dbg_options(Name, Options);
	_ -> dbg_options(Name, [])
    end.

dbg_options(Name, []) ->
    Opts = 
	case init:get_argument(generic_debug) of
	    error ->
		[];
	    _ ->
		[log, statistics]
	end,
    dbg_opts(Name, Opts);
dbg_options(Name, Opts) ->
    dbg_opts(Name, Opts).

dbg_opts(Name, Opts) ->
    case catch sys:debug_options(Opts) of
	{'EXIT',_} ->
	    format("~p: ignoring erroneous debug options - ~p~n",
		   [Name, Opts]),
	    [];
	Dbg ->
	    Dbg
    end.

get_proc_name(Pid) when is_pid(Pid) ->
    Pid;
get_proc_name({local, Name}) ->
    case process_info(self(), registered_name) of
	{registered_name, Name} ->
	    Name;
	{registered_name, _Name} ->
	    exit(process_not_registered);
	[] ->
	    exit(process_not_registered)
    end;    
get_proc_name({global, Name}) ->
    case global:whereis_name(Name) of
	undefined ->
	    exit(process_not_registered_globally);
	Pid when Pid =:= self() ->
	    Name;
	_Pid ->
	    exit(process_not_registered_globally)
    end;
get_proc_name({via, Mod, Name}) ->
    case Mod:whereis_name(Name) of
	undefined ->
	    exit({process_not_registered_via, Mod});
	Pid when Pid =:= self() ->
	    Name;
	_Pid ->
	    exit({process_not_registered_via, Mod})
    end.

get_parent() ->
    case get('$ancestors') of
	[Parent | _] when is_pid(Parent)->
            Parent;
        [Parent | _] when is_atom(Parent)->
            name_to_pid(Parent);
	_ ->
	    exit(process_was_not_started_by_proc_lib)
    end.

name_to_pid(Name) ->
    case whereis(Name) of
	undefined ->
	    case global:whereis_name(Name) of
		undefined ->
		    exit(could_not_find_registered_name);
		Pid ->
		    Pid
	    end;
	Pid ->
	    Pid
    end.

%%-----------------------------------------------------------------
%% Status information
%%-----------------------------------------------------------------
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [Name, State, Mod, _Time]] = StatusData,
    Header = gen:format_status_header("Status for generic server",
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

%% API

schedule(Event, Time) ->
    Event_list = get(local),
    put(local, [{Time + get(clock), Event} | Event_list]),
    case get(debug) of
        [] -> ok;
        Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {schedule, Event, Time})
    end,
    ok.            

schedule(LP, Event, Time) ->
    LP ! {schedule, get(name), Event, Time + get(clock)},
    case get(debug) of
        [] -> ok;
        Debug -> sys:handle_debug(Debug, fun print_event/3, LP, {schedule, Event, Time})
    end,
    ok.



%% unschedule(Event) ->
%%     Event_list = get(local),
%%     put(local, lists:keydelete(Event, 2, Event_list)),
%%     case get(debug) of
%%         [] -> ok;
%%         Debug -> sys:handle_debug(Debug, fun print_event/3, get(name), {unschedule, Event})
%%     end,
%%     ok.

print(Str) ->
    io:format("~p@~p: " ++ Str, [get(clock), get(name)]).

print(Str, Args) ->
    io:format("(~p~p: " ++ Str, [get(clock), get(name) | Args]).

println(Str) ->
    print(Str ++ "~n").

println(Str, Args) ->
    print(Str ++ "~n", Args).

get_clock() ->
    get(clock).

%% add_link(LP) ->
%%     %% set lookahead for that link to 0
%%     lookahead(LP,0),
%%     %% inform the LP for the link, so the LP will initialize a new queue for this link
%%     LP ! {add_link, self()}.


link_from(LP) ->
    %% add the queue ref
    put(queues, sets:add_element(LP, get(queues))),
    %% initialize the queue
    put(LP, queue:new()).


remove_link(LP) ->
    %% remove the lookahead
    Lookahead = get(lookahead),
    Lookahead_ = lists:keydelete(LP, 1, Lookahead),
    put(lookahead, Lookahead_),

    %% inform the LP, so the LP can move the queue events to the local queue
    LP ! {remove_link, get(name)}.


remove_links() ->
    %% removes the links of this LP
    Lookahead = get(lookahead),
    lists:foreach(fun ({LP, _}) -> remove_link(LP) end, Lookahead). % can be optimized by code inlining
                         
link_to(LP, Val) ->
    %% set lookahead for that link to 0
    Lookahead = get(lookahead),
    Lookahead_ = lists:keystore(LP, 1, Lookahead, {LP, Val}),
    put(lookahead, Lookahead_).    

